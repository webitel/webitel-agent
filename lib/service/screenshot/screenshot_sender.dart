import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:desktop_screenshot/desktop_screenshot.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:webitel_desk_track/ws/ws.dart';
import '../../core/logger.dart';

class ScreenshotSenderService {
  final String baseUrl;

  Timer? _checkerTimer;
  Timer? _screenshotTimer;

  bool _serviceStarted = false;
  bool _screenControlEnabled = false;
  Duration? _screenshotInterval;
  Duration? _currentTimerInterval;

  final _storage = SecureStorageService();

  bool _screenshotInProgress = false;
  DateTime? _lastScreenshotAt;

  static const Duration _minScreenshotGap = Duration(seconds: 1);

  /// Polling interval to sync settings with the server (1 minute as requested).
  static const Duration _checkerInterval = Duration(seconds: 15);

  ScreenshotSenderService({required this.baseUrl});

  /// Starts the service and initiates settings polling.
  void start() {
    if (_serviceStarted) return;
    _serviceStarted = true;

    // Initial fetch to set up state.
    _fetchSettings();

    // Start periodic polling to react to remote setting changes (e.g., disabling control).
    _checkerTimer = Timer.periodic(_checkerInterval, (_) => _fetchSettings());
    logger.info(
      '[Screenshot] Service started. Settings poll: $_checkerInterval',
    );
  }

  /// Stops all timers and resets the service state.
  void stop() {
    _checkerTimer?.cancel();
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    _checkerTimer = null;
    _serviceStarted = false;
    _currentTimerInterval = null;
    _screenshotInProgress = false;
    logger.info('[Screenshot] Service stopped.');
  }

  /// Fetches required agent and system settings from the server.
  Future<void> _fetchSettings() async {
    try {
      final token = await _storage.readAccessToken();
      if (token == null) return;

      var agentId = await _storage.readAgentId();
      if (agentId == null || agentId == 0) {
        agentId = await _recoverAgentId();
        if (agentId == null) return;
      }

      await Future.wait([
        _fetchScreenControl(token, agentId),
        _fetchScreenshotInterval(token),
      ]);

      // Apply changes immediately after fetching.
      _applySettings();
    } catch (e, st) {
      logger.error('[Screenshot] Failed to fetch settings:', e, st);
    }
  }

  Future<void> _fetchScreenControl(String token, int agentId) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/api/call_center/agents?page=1&size=1&fields=screen_control&id=$agentId',
      );
      final resp = await http.get(uri, headers: {'X-Webitel-Access': token});

      if (resp.statusCode == 200) {
        final js = jsonDecode(resp.body);
        final items = js['items'];
        _screenControlEnabled =
            items is List &&
            items.isNotEmpty &&
            items.first['screen_control'] == true;
      }
    } catch (e) {
      logger.error('[Screenshot] Failed to fetch screen_control: $e');
    }
  }

  Future<void> _fetchScreenshotInterval(String token) async {
    try {
      final uri = Uri.parse('$baseUrl/api/settings?name=screenshot_interval');
      final resp = await http.get(uri, headers: {'X-Webitel-Access': token});

      if (resp.statusCode == 200) {
        final js = jsonDecode(resp.body);
        final items = js['items'] as List?;
        if (items != null && items.isNotEmpty) {
          final minutes = int.tryParse(items.first['value']?.toString() ?? '');
          _screenshotInterval =
              (minutes != null && minutes > 0)
                  ? Duration(minutes: minutes)
                  : null;
        } else {
          _screenshotInterval = null;
        }
      }
    } catch (e) {
      logger.error('[Screenshot] Failed to fetch interval: $e');
      _screenshotInterval = null;
    }
  }

  /// Manages the screenshot timer based on current settings.
  void _applySettings() {
    final bool canScreenshot =
        _screenControlEnabled && _screenshotInterval != null;

    // If control was disabled remotely, kill the timer immediately.
    if (!canScreenshot) {
      if (_screenshotTimer != null) {
        _disableScreenshots();
        logger.info(
          '[Screenshot] Stopping active timer due to setting change.',
        );
      }
      return;
    }

    // Start or restart timer if settings changed.
    if (_screenshotTimer == null ||
        _currentTimerInterval != _screenshotInterval) {
      _screenshotTimer?.cancel();
      _currentTimerInterval = _screenshotInterval;

      _screenshotTimer = Timer.periodic(_screenshotInterval!, (timer) {
        // Double-check flags inside the tick in case polling changed them just now.
        if (_screenControlEnabled && _screenshotInterval != null) {
          screenshot();
        } else {
          _disableScreenshots();
        }
      });

      logger.info(
        '[Screenshot] Timer active. Next capture in: $_screenshotInterval',
      );
    }
  }

  void _disableScreenshots() {
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    _currentTimerInterval = null;
  }

  Future<int?> _recoverAgentId() async {
    try {
      final socket = WebitelSocket.instance;
      await socket.ready;
      final session = await socket.getAgentSession();
      await _storage.writeAgentId(session.agentId);
      return session.agentId;
    } catch (e) {
      return null;
    }
  }

  Future<void> screenshot() async {
    if (_screenshotInProgress) return;

    final now = DateTime.now();
    if (_lastScreenshotAt != null &&
        now.difference(_lastScreenshotAt!) < _minScreenshotGap) {
      return;
    }

    _screenshotInProgress = true;
    _lastScreenshotAt = now;

    try {
      final token = await _storage.readAccessToken() ?? 'unknown';
      final agentId = await _storage.readAgentId() ?? 'unknown_user';

      final date =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final time =
          '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';
      final filename = 'scr_ss_${agentId}_${date}_$time.png';

      Uint8List? bytes;

      if (defaultTargetPlatform == TargetPlatform.macOS) {
        if (!await ScreenCapturer.instance.isAccessAllowed()) {
          await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
          return;
        }
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/$filename';
        final capture = await ScreenCapturer.instance.capture(
          mode: CaptureMode.screen,
          silent: true,
          imagePath: path,
        );
        if (capture != null) bytes = await File(path).readAsBytes();
      } else if (defaultTargetPlatform == TargetPlatform.windows) {
        bytes = await DesktopScreenshot().getScreenshot();
      }

      if (bytes == null || bytes.isEmpty) return;

      final uri = Uri.parse(
        '$baseUrl/api/storage/file/$agentId/upload',
      ).replace(
        queryParameters: {
          'channel': 'screenrecording',
          'access_token': token,
          'thumbnail': 'true',
          'name': filename,
        },
      );

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'image/png'},
        body: bytes,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        logger.info('[Screenshot] Uploaded: $filename');
      } else {
        logger.error('[Screenshot] Upload failed: ${response.statusCode}');
      }
    } catch (e, st) {
      logger.error('[Screenshot] Error:', e, st);
    } finally {
      _screenshotInProgress = false;
    }
  }
}
