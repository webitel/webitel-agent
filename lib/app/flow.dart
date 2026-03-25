import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/core/storage/storage.dart';
import 'package:webitel_desk_track/service/tray/tray.dart';
import 'package:window_manager/window_manager.dart';

import 'package:webitel_desk_track/ws/socket_manager.dart';
import 'package:webitel_desk_track/app/recording_manager.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/auth/login.dart';
import 'package:webitel_desk_track/service/auth/token_watcher.dart';
import 'package:webitel_desk_track/service/screenshot/sender.dart';

enum AppStatus { idle, authenticating, ready, failure }

class AppFlow {
  // Singleton instance
  static final AppFlow instance = AppFlow._();
  AppFlow._();

  // Internal shared storage instance
  final IStorageService _storage = SharedPrefsService();

  // Public getter to allow external initialization (e.g., in AppInitializer)
  IStorageService get storage => _storage;

  ScreenshotSenderService? _screenshotService;
  RecordingManager? _recordingManager;
  SocketManager? _socketManager;
  TokenWatcher? _tokenWatcher;

  final ValueNotifier<AppStatus> status = ValueNotifier(AppStatus.idle);

  /// Entry point to start the application flow
  Future<void> start() async {
    if (status.value == AppStatus.authenticating) return;

    status.value = AppStatus.authenticating;
    logger.info('[AppFlow] Starting application sequence...');

    // Initialize tray with storage first to ensure UI is ready
    await TrayService.init(AppFlow.instance.storage);

    final token = await _ensureToken();

    if (token == null) {
      logger.warn('[AppFlow] No valid token found. Aborting startup.');
      status.value = AppStatus.idle;
      return;
    }

    await _initializeServices(token);
  }

  /// Validates existing token or performs fresh login if needed
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

  /// Dependency Injection and Service Setup
  Future<void> _initializeServices(String token) async {
    try {
      logger.info('[AppFlow] Initializing core modules...');

      // 1. Screenshot Service
      _screenshotService = ScreenshotSenderService(
        baseUrl: AppConfig.instance.baseUrl,
        storage: _storage,
      )..start();

      // 2. Recording Manager
      _recordingManager = RecordingManager(storage: _storage);

      // 3. Socket Manager
      _socketManager = SocketManager(
        baseUrl: AppConfig.instance.baseUrl,
        wsUrl: AppConfig.instance.webitelWsUrl,
        token: token,
        storage: _storage,
      );

      final success = await _socketManager!.connectAndAuthenticate();

      if (success) {
        final socket = _socketManager!.socket;

        // Wire up all dependencies for the socket handlers
        socket.initServices(screenshot: _screenshotService!, storage: _storage);

        _recordingManager!.attachSocket(socket);
        TrayService.instance.attachSocket(socket);

        // 4. Token Watcher to handle background expiration
        _tokenWatcher = TokenWatcher(
          baseUrl: AppConfig.instance.baseUrl,
          onExpired: interactiveRelogin,
          storage: _storage,
        )..start();

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

  /// Forces UI to front and requests new credentials from the user
  Future<void> interactiveRelogin() async {
    logger.info('[AppFlow] Interactive relogin requested');
    await shutdown();

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
      if (!await windowManager.isVisible()) await windowManager.show();
      await windowManager.focus();
    }

    final loginService = LoginService(storage: _storage);
    final ok = await loginService.performLogin();

    if (ok) {
      final newToken = await _storage.readAccessToken();
      if (newToken != null) await _initializeServices(newToken);
    }
  }

  /// Clean teardown of all active instances before app close or relogin
  Future<void> shutdown() async {
    logger.info('[AppFlow] Performing graceful shutdown...');

    _screenshotService?.stop();
    _screenshotService = null;

    await _recordingManager?.stopAllAndUpload();
    _recordingManager = null;

    await _socketManager?.disconnect();
    _socketManager = null;

    _tokenWatcher?.stop();
    _tokenWatcher = null;

    status.value = AppStatus.idle;
    logger.info('[AppFlow] Shutdown complete.');
  }
}
