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
import 'package:webitel_desk_track/ws/socket_manager.dart';
import 'package:window_manager/window_manager.dart';

enum AppStatus { idle, authenticating, ready, failure }

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

  /// Entry point to start the application flow.
  Future<void> start() async {
    if (status.value == AppStatus.authenticating) return;

    status.value = AppStatus.authenticating;
    logger.info('[AppFlow] Starting application sequence...');

    // [GUARD] Register listener to catch the close event
    windowManager.addListener(this);

    final token = await _ensureToken();
    if (token == null) {
      logger.warn('[AppFlow] No valid token found. Aborting startup.');
      status.value = AppStatus.idle;
      return;
    }

    await _initializeWithToken(token);
  }

  /// [PROTOCOL] Intercept close event to perform cleanup BEFORE exit
  @override
  void onWindowClose() async {
    logger.warn('[AppFlow] Close requested. Suspending exit for cleanup...');

    // [GUARD] Ensure we have time to finish async tasks like WebRTC stops or uploads
    await windowManager.setPreventClose(true);

    try {
      // [LOGIC] Execute full cleanup (Stop WebRTC, Sockets, and File uploads)
      await shutdown();
      logger.info('[AppFlow] Cleanup successful. Terminating process.');
    } catch (e, st) {
      logger.error('[AppFlow] Cleanup failed during close', e, st);
    } finally {
      // [FINAL] Fully close the application and kill the process
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
  Future<void> _initializeWithToken(String token) async {
    try {
      logger.info('[AppFlow] Initializing core modules...');

      screenshotService ??= ScreenshotSenderService(
        baseUrl: AppConfig.instance.baseUrl,
        storage: _storage,
      );
      screenshotService!.start();

      recordingManager ??= RecordingManager(storage: _storage);

      socketManager ??= SocketManager(
        baseUrl: AppConfig.instance.baseUrl,
        wsUrl: AppConfig.instance.webitelWsUrl,
        token: token,
        storage: _storage,
      );

      final connected = await socketManager!.connectAndAuthenticate();

      if (connected) {
        final socket = socketManager!.socket;
        socket.initServices(screenshot: screenshotService!, storage: _storage);
        recordingManager!.attachSocket(socket);
        TrayService.instance.attachSocket(socket);

        _tokenWatcher ??= TokenWatcher(
          baseUrl: AppConfig.instance.baseUrl,
          onExpired: interactiveRelogin,
          storage: _storage,
        );
        _tokenWatcher!.start();

        status.value = AppStatus.ready;
        logger.info('[AppFlow] All services are ready and connected.');
      } else {
        throw Exception('WebSocket authentication failed');
      }
    } catch (e, st) {
      logger.error('[AppFlow] Critical initialization failure', e, st);
      status.value = AppStatus.failure;
      await interactiveRelogin();
    }
  }

  Future<void> interactiveRelogin() async {
    logger.info('[AppFlow] Interactive relogin requested');
    await _storage.deleteAccessToken();
    await shutdown();

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
      if (!await windowManager.isVisible()) await windowManager.show();
      await windowManager.focus();
    }

    final loginService = LoginService(storage: _storage);
    final ok = await loginService.performLogin();

    if (ok) {
      await Future.delayed(const Duration(milliseconds: 800));
      final newToken = await _storage.readAccessToken();
      if (newToken != null) await _initializeWithToken(newToken);
    }
  }

  /// Clean teardown of all active instances.
  Future<void> shutdown() async {
    logger.info('[AppFlow] Performing graceful shutdown...');

    windowManager.removeListener(this);

    screenshotService?.stop();
    screenshotService = null;

    // [GUARD] Critical: Stops WebRTC streams and finishes file writing
    await recordingManager?.stopAllAndUpload();
    recordingManager = null;

    // [LOGIC] Sends 'offline' state to server before closing
    await socketManager?.disconnect();
    socketManager = null;

    _tokenWatcher?.stop();
    _tokenWatcher = null;

    status.value = AppStatus.idle;
  }
}
