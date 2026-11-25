import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/app/recording_manager.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/auth/login.dart';
import 'package:webitel_desk_track/service/auth/token_watcher.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/core/storage/storage.dart';
import 'package:webitel_desk_track/service/screenshot/sender.dart';
import 'package:webitel_desk_track/service/tray/tray.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/ws/core/error.dart';
import 'package:webitel_desk_track/ws/socket_manager.dart';
import 'package:window_manager/window_manager.dart';

enum AppStatus { idle, authenticating, ready, failure }

enum _InitResult { ready, tokenRejected, retrying, aborted }

class AppFlow extends WindowListener {
  // [LOGIC] Private constructor for Singleton pattern
  AppFlow._();
  static final AppFlow instance = AppFlow._();

  final IStorageService _storage = SharedPrefsService();

  ScreenshotSenderService? screenshotService;
  RecordingManager? recordingManager;
  SocketManager? socketManager;
  TokenWatcher? _tokenWatcher;

  final ValueNotifier<AppStatus> status = ValueNotifier(AppStatus.idle);

  IStorageService get storage => _storage;

  // [GUARD] Track listener registration to prevent duplicate event triggers after re-login
  bool _isListenerRegistered = false;

  // Bumped by shutdown(); an initialization that started before it must stop.
  int _session = 0;
  Future<void>? _relogin;
  Timer? _initRetryTimer;
  int _initRetries = 0;

  /// Entry point to start the application flow.
  Future<void> start() async {
    if (status.value == AppStatus.authenticating) return;

    status.value = AppStatus.authenticating;
    logger.info('[AppFlow] Starting application sequence...');

    // [GUARD] Ensure window manager listener is attached only once per lifecycle
    if (!_isListenerRegistered) {
      windowManager.addListener(this);
      _isListenerRegistered = true;
      logger.info('[AppFlow] WindowManager listener registered.');
    }

    final token = await _ensureToken();
    if (token == null) {
      status.value = AppStatus.idle;
      return;
    }

    if (await _initializeWithToken(token) == _InitResult.tokenRejected) {
      await interactiveRelogin();
    }
  }

  // The close button only hides the window: the agent keeps recording and
  // reporting from the tray. A real exit goes through quit() (tray "Close").
  @override
  void onWindowClose() async {
    logger.info('[AppFlow] Close requested. Hiding window to tray.');
    // hide() also removes the taskbar button. setSkipTaskbar() must not be used:
    // window_manager 0.4.x creates its ITaskbarList only in waitUntilReadyToShow(),
    // so it dereferences a null pointer and kills the process (0xC0000005).
    await windowManager.hide();
  }

  Future<void> showWindow() async {
    if (!await windowManager.isVisible()) await windowManager.show();
    await windowManager.focus();
  }

  // Stops recordings (finalizing them on the server), reports offline, exits.
  Future<void> quit() async {
    logger.warn('[AppFlow] Quit requested. Running cleanup before exit...');
    try {
      await shutdown().timeout(const Duration(seconds: 15));
      logger.info('[AppFlow] Cleanup successful. Terminating process.');
    } catch (e, st) {
      logger.error('[AppFlow] Cleanup failed during quit', e, st);
    } finally {
      await windowManager.setPreventClose(false);
      exit(0);
    }
  }

  /// Validates existing token or performs fresh login.
  Future<String?> _ensureToken() async {
    var token = await _storage.readAccessToken();
    final loginService = LoginService(storage: _storage);

    if (token == null || token.isEmpty) {
      logger.info('[AppFlow] Token missing, performing login...');
      final ok = await loginService.performLogin();
      if (!ok) return null;
      token = await _storage.readAccessToken();
    } else {
      try {
        final uri = Uri.parse('${AppConfig.instance.baseUrl}/api/userinfo');
        final resp = await http
            .get(uri, headers: {'X-Webitel-Access': token})
            .timeout(const Duration(seconds: 5));

        if (resp.statusCode == 401) {
          logger.warn('[AppFlow] Token expired (401), re-authenticating...');
          final ok = await loginService.performLogin();
          if (!ok) return null;
          token = await _storage.readAccessToken();
        }
      } catch (e) {
        logger.error('[AppFlow] Connectivity issue during token validation', e);
      }
    }
    return token;
  }

  /// Dependency Injection and Service Setup.
  // Never starts a relogin itself: a relogin calls this, so awaiting one here
  // would wait on itself forever.
  Future<_InitResult> _initializeWithToken(String token) async {
    final session = _session;
    _initRetryTimer?.cancel();
    _initRetryTimer = null;

    final screenshot =
        screenshotService ??= ScreenshotSenderService(
          baseUrl: AppConfig.instance.baseUrl,
          storage: _storage,
        );
    final recorder = recordingManager ??= RecordingManager(storage: _storage);
    final sockets =
        socketManager ??= SocketManager(
          baseUrl: AppConfig.instance.baseUrl,
          wsUrl: AppConfig.instance.webitelWsUrl,
          token: token,
          storage: _storage,
        );

    try {
      logger.info('[AppFlow] Initializing core modules...');
      await sockets.connectAndAuthenticate();
    } on AuthRejectedException catch (e) {
      if (session != _session) return _InitResult.aborted;
      logger.error('[AppFlow] Token rejected by server', e);
      status.value = AppStatus.failure;
      return _InitResult.tokenRejected;
    } catch (e, st) {
      if (session != _session) return _InitResult.aborted;
      // Server unreachable (no VPN, Wi-Fi not up yet, server restart): keep the
      // token and retry instead of parking an unattended PC on the login page.
      logger.error('[AppFlow] Server unavailable, will retry', e, st);
      status.value = AppStatus.failure;
      _scheduleInitRetry();
      return _InitResult.retrying;
    }
    if (session != _session) return _InitResult.aborted;
    _initRetries = 0;

    final socket = sockets.socket;
    try {
      await socket.getAgentSession();
    } catch (e) {
      logger.warn('[AppFlow] Agent session not loaded yet: $e');
    }
    if (session != _session) return _InitResult.aborted;

    screenshot.start();
    socket.markAppInitialized();
    socket.initServices(screenshot: screenshot, storage: _storage);
    recorder.attachSocket(socket);
    TrayService.instance.attachSocket(socket);
    socket.onAuthRejected = interactiveRelogin;

    _tokenWatcher ??= TokenWatcher(
      baseUrl: AppConfig.instance.baseUrl,
      onExpired: interactiveRelogin,
      storage: _storage,
    );
    _tokenWatcher!.start();

    status.value = AppStatus.ready;
    logger.info('[AppFlow] All services are ready and connected.');
    return _InitResult.ready;
  }

  void _scheduleInitRetry() {
    final session = _session;
    _initRetries++;
    final seconds = (5 * _initRetries).clamp(5, 60);
    logger.info('[AppFlow] Retrying initialization in ${seconds}s');
    _initRetryTimer?.cancel();
    _initRetryTimer = Timer(Duration(seconds: seconds), () async {
      _initRetryTimer = null;
      final current = await _storage.readAccessToken();
      if (session != _session || current == null || current.isEmpty) return;
      if (await _initializeWithToken(current) == _InitResult.tokenRejected) {
        await interactiveRelogin();
      }
    });
  }

  // Every relogin trigger (token watcher, rejected token, tray) joins one flow.
  Future<void> interactiveRelogin() {
    return _relogin ??= _interactiveRelogin().whenComplete(
      () => _relogin = null,
    );
  }

  Future<void> _interactiveRelogin() async {
    logger.info('[AppFlow] Interactive relogin requested');
    final rejectedToken = await _storage.readAccessToken();
    await _storage.deleteAccessToken();
    // The next user on this PC may be a different agent.
    await _storage.deleteAgentId();
    await shutdown();

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
      await showWindow();
    }

    var rejected = rejectedToken;
    while (true) {
      final loginService = LoginService(storage: _storage);
      final ok = await loginService.performLogin(rejectedToken: rejected);
      if (!ok) return;

      await Future.delayed(const Duration(milliseconds: 800));
      final newToken = await _storage.readAccessToken();
      if (newToken == null) return;
      if (await _initializeWithToken(newToken) != _InitResult.tokenRejected) {
        return;
      }
      // The server refused the token the login just produced: log in again.
      rejected = newToken;
      await _storage.deleteAccessToken();
      await shutdown();
    }
  }

  /// Clean teardown of all active instances.
  Future<void> shutdown() async {
    logger.info('[AppFlow] Performing graceful shutdown...');
    _session++;
    _initRetryTimer?.cancel();
    _initRetryTimer = null;

    // [LOGIC] Keep the listener active for the next login session
    // Only remove if we are genuinely destroying the singleton, otherwise it's redundant

    // Detach before awaiting so an init starting meanwhile builds fresh ones.
    final screenshot = screenshotService;
    final recorder = recordingManager;
    final sockets = socketManager;
    screenshotService = null;
    recordingManager = null;
    socketManager = null;

    screenshot?.stop();

    // [GUARD] Critical: Stops WebRTC streams and finishes file writing
    await recorder?.stopAllAndUpload();

    // [LOGIC] Sends 'offline' state to server before closing
    await sockets?.disconnect();

    _tokenWatcher?.stop();
    _tokenWatcher = null;

    status.value = AppStatus.idle;
  }
}
