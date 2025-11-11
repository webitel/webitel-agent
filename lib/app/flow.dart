// lib/app/app_flow.dart
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/app/recording_manager.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/auth/login.dart';
import 'package:webitel_desk_track/service/auth/token_watcher.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:webitel_desk_track/service/screenshot/screenshot_sender.dart';
import 'package:webitel_desk_track/service/control/agent_control.dart';
import 'package:webitel_desk_track/service/system/tray.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/ws/manager.dart';

/// Central app lifecycle: login → initialize services → attach socket, recorders, screenshot.
class AppFlow {
  static final _storage = SecureStorageService();
  static ScreenshotSenderService? screenshotService;
  static AgentControlService? agentControlService;
  static RecordingManager? recordingManager;
  static SocketManager? socketManager;
  static TokenWatcher? _tokenWatcher;

  /// Start / resume the app flow. Idempotent (won't start twice).
  static Future<void> start() async {
    final token = await _ensureToken();
    if (token == null) {
      logger.warn('[AppFlow] No token, aborting startup.');
      return;
    }

    await _initializeWithToken(token);
  }

  /// Ensures we have a valid token. If missing, trigger login flow.
  static Future<String?> _ensureToken() async {
    var token = await _storage.readAccessToken();

    final uri = Uri.parse('${AppConfig.instance.baseUrl}/api/userinfo');
    final resp = await http.get(
      uri,
      headers: {'X-Webitel-Access': token ?? ''},
    );

    if (token == null || token.isEmpty || resp.statusCode == 401) {
      // need to login
      final ok = await LoginService.performLogin();
      if (!ok) return null;
      token = await _storage.readAccessToken();
    }
    return token;
  }

  /// Initialize services that require token/config.
  static Future<void> _initializeWithToken(String token) async {
    // Screenshot service
    screenshotService ??= ScreenshotSenderService(
      baseUrl: AppConfig.instance.baseUrl,
    );
    screenshotService!.start();

    // Agent control polling
    // agentControlService ??= AgentControlService(
    //   baseUrl: AppConfig.instance.baseUrl,
    // );
    // agentControlService!.start();

    // Recording manager (manages call/screen recorders)
    recordingManager ??= RecordingManager();

    // Socket manager: connect + authenticate
    socketManager ??= SocketManager(
      baseUrl: AppConfig.instance.baseUrl,
      wsUrl: AppConfig.instance.webitelWsUrl,
      token: token,
    );

    final connected = await socketManager!.connectAndAuthenticate();
    if (!connected) {
      logger.error(
        '[AppFlow] Socket connect/auth failed, attempting interactive re-login',
      );
      await _interactiveRelogin();
      return;
    }

    // Token watcher: monitor token expiration and trigger re-login
    _tokenWatcher ??= TokenWatcher(
      baseUrl: AppConfig.instance.baseUrl,
      onExpired: _interactiveRelogin,
    );
    _tokenWatcher!.start();

    // attach socket to services
    recordingManager!.attachSocket(socketManager!.socket);
    TrayService.instance.attachSocket(socketManager!.socket);

    // listen for socket auth failures and handle centrally
    socketManager!.onAuthenticationFailed = () async {
      logger.warn('[AppFlow] Socket authentication failed, doing full restart');
      await _interactiveRelogin();
    };
  }

  /// Do interactive relogin (clears token, prompts UI login, restarts services)
  static Future<void> _interactiveRelogin() async {
    await _storage.deleteAccessToken();

    // stop everything gracefully
    await shutdown();

    // present login UI to user
    final ok = await LoginService.performLogin();
    if (!ok) {
      logger.warn('[AppFlow] Relogin cancelled by user');
      return;
    }

    final newToken = await _storage.readAccessToken();
    if (newToken == null || newToken.isEmpty) {
      logger.error('[AppFlow] No token after relogin');
      return;
    }

    // restart initialization
    await _initializeWithToken(newToken);
  }

  /// Gracefully stop services and recorders (used on window close or restart)
  static Future<void> shutdown() async {
    logger.info('[AppFlow] Shutting down services and recorders');

    // Stop accepting new timers in screenshot & agent control
    try {
      screenshotService?.stop();
    } catch (e, st) {
      logger.warn('[AppFlow] screenshotService.stop error: $e\n$st');
    }

    screenshotService = null;

    try {
      agentControlService?.stop();
    } catch (e, st) {
      logger.warn('[AppFlow] agentControlService.stop error: $e\n$st');
    }

    agentControlService = null;

    // Stop recording manager (stops recorders and uploads pending files)
    try {
      await recordingManager?.stopAllAndUpload();
    } catch (e, st) {
      logger.warn('[AppFlow] recordingManager.stopAllAndUpload error: $e\n$st');
    }
    recordingManager = null;

    // Disconnect socket
    try {
      await socketManager?.disconnect();
    } catch (e, st) {
      logger.warn('[AppFlow] socketManager.disconnect error: $e\n$st');
    }
    socketManager = null;

    // Stop token watcher
    try {
      await _tokenWatcher?.stop();
    } catch (e, st) {
      logger.warn('[AppFlow] tokenWatcher.stop error: $e\n$st');
    }
    _tokenWatcher = null;
  }
}
