import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:desktop_screenshot/desktop_screenshot.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/ws/webitel_socket.dart';
import '../../core/logger/logger.dart';

class ScreenshotSenderService {
  final String baseUrl;
  final IStorageService _storage;

  Timer? _checkerTimer;
  Timer? _screenshotTimer;

  bool _serviceStarted = false;
  bool _screenControlEnabled = false;
  Duration? _screenshotInterval;
  Duration? _currentTimerInterval;

  bool _screenshotInProgress = false;
  DateTime? _lastScreenshotAt;

  static const Duration _minScreenshotGap = Duration(seconds: 5);
  static const Duration _checkerInterval = Duration(seconds: 15);

  ScreenshotSenderService({
    required this.baseUrl,
    required IStorageService storage,
  }) : _storage = storage;

  /// Public getter for other services to check current permission state
  bool get isControlEnabled => _screenControlEnabled;

  /// Starts the service and initiates background settings polling
  void start() {
    if (_serviceStarted) return;
    _serviceStarted = true;

    // Immediate fetch on startup
    _fetchSettings();

    // Periodic polling to stay synced with remote changes
    _checkerTimer = Timer.periodic(_checkerInterval, (_) => _fetchSettings());

    logger.info(
      '[SCREENSHOT_SERVICE] Started | Poll interval: ${_checkerInterval.inSeconds}s',
    );
  }

  /// Stops all background tasks and cleans up resources
  void stop() {
    _checkerTimer?.cancel();
    _stopScreenshotTimer();
    _checkerTimer = null;
    _serviceStarted = false;
    _screenshotInProgress = false;
    logger.info('[SCREENSHOT_SERVICE] Stopped');
  }

  /// Helper to generate a standardized filename for both manual and auto captures
  /// Format: scr_ss_[agentId]_[YYYYMMDD_HHMMSS].png
  String _generateFilename(int agentId, DateTime time) {
    final String timestamp =
        "${time.year}"
        "${time.month.toString().padLeft(2, '0')}"
        "${time.day.toString().padLeft(2, '0')}_"
        "${time.hour.toString().padLeft(2, '0')}"
        "${time.minute.toString().padLeft(2, '0')}"
        "${time.second.toString().padLeft(2, '0')}";

    return 'scr_ss_${agentId}_$timestamp.png';
  }

  /// Fetches latest agent configuration and screenshot intervals from API
  Future<void> _fetchSettings() async {
    try {
      final token = await _storage.readAccessToken();
      if (token == null || token.isEmpty) return;

      var agentId = await _storage.readAgentId();
      if (agentId == null || agentId == 0) {
        agentId = await _recoverAgentId();
        if (agentId == null) return;
      }

      // Execute network requests concurrently for better performance
      await Future.wait([
        _fetchScreenControl(token, agentId),
        _fetchScreenshotInterval(token),
      ]);

      _applySettings();
    } catch (e, st) {
      logger.error('[SCREENSHOT_SERVICE] Settings fetch failure', e, st);
    }
  }

  Future<void> _fetchScreenControl(String token, int agentId) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/api/call_center/agents?page=1&size=1&fields=screen_control&id=$agentId',
      );
      final resp = await http
          .get(uri, headers: {'X-Webitel-Access': token})
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final js = jsonDecode(resp.body);
        final items = js['items'];
        _screenControlEnabled =
            items is List &&
            items.isNotEmpty &&
            items.first['screen_control'] == true;
      }
    } catch (e) {
      logger.warn(
        '[SCREENSHOT_SERVICE] Failed to update screen_control status: $e',
      );
    }
  }

  Future<void> _fetchScreenshotInterval(String token) async {
    try {
      final uri = Uri.parse('$baseUrl/api/settings?name=screenshot_interval');
      final resp = await http
          .get(uri, headers: {'X-Webitel-Access': token})
          .timeout(const Duration(seconds: 10));

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
      logger.warn('[SCREENSHOT_SERVICE] Failed to update interval setting: $e');
      _screenshotInterval = null;
    }
  }

  /// Evaluates current state and manages the screenshot capture timer
  void _applySettings() {
    final bool isActive = _screenControlEnabled && _screenshotInterval != null;

    if (!isActive) {
      if (_screenshotTimer != null) {
        _stopScreenshotTimer();
        logger.info(
          '[SCREENSHOT_SERVICE] Capturing paused: control disabled or interval missing',
        );
      }
      return;
    }

    // Update timer only if the interval value has changed
    if (_screenshotTimer == null ||
        _currentTimerInterval != _screenshotInterval) {
      _stopScreenshotTimer();
      _currentTimerInterval = _screenshotInterval;

      _screenshotTimer = Timer.periodic(_screenshotInterval!, (_) => capture());

      logger.info(
        '[SCREENSHOT_SERVICE] Capture timer initialized | Interval: ${_screenshotInterval!.inMinutes}m',
      );
    }
  }

  void _stopScreenshotTimer() {
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
      logger.warn('[SCREENSHOT_SERVICE] Agent ID recovery failure: $e');
      return null;
    }
  }

  /// Triggers a screen capture and uploads it to the storage server.
  /// Used for both automated timer-based captures and manual triggers.
  Future<void> capture() async {
    if (_screenshotInProgress) return;

    final now = DateTime.now();

    // Guard: Prevent overlapping captures or rapid firing (debounce)
    if (_lastScreenshotAt != null &&
        now.difference(_lastScreenshotAt!) < _minScreenshotGap) {
      return;
    }

    _screenshotInProgress = true;
    _lastScreenshotAt = now;

    try {
      final token = await _storage.readAccessToken() ?? '';
      final agentId = await _storage.readAgentId() ?? 0;

      if (token.isEmpty || agentId == 0) {
        logger.error(
          '[SCREENSHOT_SERVICE] Capture aborted: Missing authentication',
        );
        return;
      }

      // Generate standardized filename
      final filename = _generateFilename(agentId, now);

      Uint8List? bytes;

      // Platform specific capture logic
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        if (!await ScreenCapturer.instance.isAccessAllowed()) {
          logger.warn('[SCREENSHOT_SERVICE] macOS permission denied');
          return;
        }
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/$filename';

        await ScreenCapturer.instance.capture(
          mode: CaptureMode.screen,
          silent: true,
          imagePath: path,
        );

        final file = File(path);
        if (await file.exists()) {
          bytes = await file.readAsBytes();
          await file.delete(); // Cleanup temp file
        }
      } else if (defaultTargetPlatform == TargetPlatform.windows) {
        bytes = await DesktopScreenshot().getScreenshot();
      }

      if (bytes == null || bytes.isEmpty) {
        logger.warn('[SCREENSHOT_SERVICE] Capture failed: Buffer is empty');
        return;
      }

      // Construct upload URI with query parameters
      final uri = Uri.parse(
        '$baseUrl/api/storage/file/$agentId/upload',
      ).replace(
        queryParameters: {
          'channel': 'screenrecording',
          'access_token': token,
          'name': filename,
        },
      );

      // Perform HTTP POST upload
      final response = await http
          .post(uri, headers: {'Content-Type': 'image/png'}, body: bytes)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        logger.info('[SCREENSHOT_SERVICE] Upload successful: $filename');
      } else {
        logger.error(
          '[SCREENSHOT_SERVICE] Upload failed | Status: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logger.error('[SCREENSHOT_SERVICE] Critical capture error', e, st);
    } finally {
      _screenshotInProgress = false;
    }
  }
}
