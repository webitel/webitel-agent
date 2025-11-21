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

  // Checker: fetch controls & interval periodically (every 3 minutes)
  Timer? _checkerTimer;

  // Timer that triggers actual screenshot uploads with configured interval
  Timer? _screenshotTimer;

  // Current values
  bool _serviceStarted = false;
  bool _screenControlEnabled = false; // from agents endpoint
  Duration _screenshotInterval = const Duration(minutes: 30); // default

  // store what interval the current screenshot timer was created with
  Duration? _currentTimerInterval;

  final _secureStorage = SecureStorageService();

  // Prevent concurrent screenshot() runs
  bool _screenshotInProgress = false;

  // Prevent near-duplicate screenshots caused by race conditions
  DateTime? _lastScreenshotAt;

  // Minimal allowed gap between screenshots (safety)
  static const Duration _minScreenshotGap = Duration(seconds: 1);

  // Checker interval
  static const Duration _checkerInterval = Duration(minutes: 3);

  ScreenshotSenderService({required this.baseUrl});

  /// Start the background checker.
  void start() {
    if (_serviceStarted) return;
    _serviceStarted = true;

    // Run immediately, then every 3 minutes
    _fetchControlsAndInterval();
    _checkerTimer = Timer.periodic(
      _checkerInterval,
      (_) => _fetchControlsAndInterval(),
    );

    logger.info('[Screenshot] Service started.');
  }

  /// Stop everything
  void stop() {
    _checkerTimer?.cancel();
    _screenshotTimer?.cancel();
    _serviceStarted = false;
    _screenControlEnabled = false;
    _currentTimerInterval = null;
    _screenshotInProgress = false;
    logger.info('[Screenshot] Service stopped.');
  }

  /// Fetch screen_control and screenshot_interval.
  /// IMPORTANT: this method does not call itself recursively.
  Future<void> _fetchControlsAndInterval() async {
    try {
      final token = await _secureStorage.readAccessToken();
      if (token == null) {
        logger.warn('[Screenshot] Missing token → skipping fetch.');
        return;
      }

      int? agentId = await _secureStorage.readAgentId();
      if (agentId == null) {
        logger.warn(
          '[Screenshot] Missing agentId → trying to fetch via WebSocket...',
        );
        try {
          final socket = WebitelSocket.instance;
          await socket.ready;
          final session = await socket.getAgentSession();
          agentId = session.agentId;
          await _secureStorage.writeAgentId(agentId);
          logger.info('[Screenshot] agentId restored from session: $agentId');
          // continue execution with recovered agentId (no recursive call)
        } catch (e, st) {
          logger.error(
            '[Screenshot] Failed to recover agentId via socket:',
            e,
            st,
          );
          return;
        }
      }

      // At this point we have token and agentId
      await _fetchScreenControl(token, agentId);
      await _fetchScreenshotInterval(token);
    } catch (e, st) {
      logger.error('[Screenshot] failed to fetch control/interval:', e, st);
    }
  }

  Future<void> _fetchScreenControl(String token, int agentId) async {
    try {
      final agentsUri = Uri.parse(
        '$baseUrl/api/call_center/agents?page=1&size=1&fields=screen_control&id=$agentId',
      );

      final agentsResp = await http.get(
        agentsUri,
        headers: {'X-Webitel-Access': token},
      );

      if (agentsResp.statusCode != 200) {
        logger.warn(
          '[Screenshot] agents fetch failed: ${agentsResp.statusCode} ${agentsResp.body}',
        );
        return;
      }

      final js = jsonDecode(agentsResp.body);
      final items = js['items'];
      if (items is! List || items.isEmpty) {
        logger.warn('[Screenshot] agents response missing items or empty.');
        return;
      }

      final dynamic scValue = items.first['screen_control'];
      final bool enabled = scValue != null && scValue == true;
      logger.info('[Screenshot] fetched screen_control: $enabled');

      if (enabled != _screenControlEnabled) {
        _screenControlEnabled = enabled;
        if (_screenControlEnabled) {
          logger.info(
            '[Screenshot] screen_control enabled → starting screenshots',
          );
          _startScreenshotsIfNeeded();
        } else {
          logger.info(
            '[Screenshot] screen_control disabled/missing → stopping screenshots',
          );
          _stopScreenshots();
        }
      }
    } catch (e, st) {
      logger.error('[Screenshot] error fetching screen_control:', e, st);
    }
  }

  Future<void> _fetchScreenshotInterval(String token) async {
    try {
      final settingsUri = Uri.parse(
        '$baseUrl/api/settings?name=screenshot_interval',
      );

      final settingsResp = await http.get(
        settingsUri,
        headers: {'X-Webitel-Access': token},
      );

      if (settingsResp.statusCode != 200) {
        logger.warn(
          '[Screenshot] settings fetch failed: ${settingsResp.statusCode} ${settingsResp.body}',
        );
        return;
      }

      final js = jsonDecode(settingsResp.body);
      final items = js['items'];
      if (items is! List || items.isEmpty) {
        logger.warn('[Screenshot] settings response missing items or empty.');
        return;
      }

      final value = items.first['value'];
      final minutes = int.tryParse(value.toString());
      if (minutes == null || minutes <= 0) {
        logger.warn('[Screenshot] invalid screenshot_interval value: $value');
        return;
      }

      final newInterval = Duration(minutes: minutes);
      if (newInterval != _screenshotInterval) {
        logger.info(
          '[Screenshot] interval updated from $_screenshotInterval to $newInterval',
        );
        _screenshotInterval = newInterval;
        if (_screenControlEnabled) {
          _restartScreenshotTimer();
        }
      }
    } catch (e, st) {
      logger.error('[Screenshot] error fetching screenshot_interval:', e, st);
    }
  }

  void _startScreenshotsIfNeeded() {
    if (!_screenControlEnabled) return;

    // If a timer is already running with the correct interval, do nothing.
    if (_screenshotTimer != null &&
        _screenshotTimer!.isActive &&
        _currentTimerInterval == _screenshotInterval) {
      logger.info(
        '[Screenshot] screenshot timer already running with interval $_screenshotInterval — skipping start.',
      );
      return;
    }

    _restartScreenshotTimer();
  }

  void _restartScreenshotTimer() {
    _screenshotTimer?.cancel();

    _screenshotTimer = Timer.periodic(_screenshotInterval, (_) => screenshot());
    _currentTimerInterval = _screenshotInterval;

    // Take first shot immediately but guard against near-duplicates
    // (screenshot() itself guards against concurrent and near-duplicate runs).
    screenshot();
  }

  void _stopScreenshots() {
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    _currentTimerInterval = null;
    logger.info('[Screenshot] screenshot timer stopped.');
  }

  /// Captures a screenshot depending on the platform and uploads it to the server.
  Future<void> screenshot() async {
    // Avoid concurrent executions
    if (_screenshotInProgress) {
      logger.info(
        '[Screenshot] skipped because another screenshot is in progress.',
      );
      return;
    }

    // Avoid near-duplicate screenshots (race protection)
    final now = DateTime.now();
    if (_lastScreenshotAt != null &&
        now.difference(_lastScreenshotAt!) < _minScreenshotGap) {
      logger.info(
        '[Screenshot] skipped because last screenshot was ${now.difference(_lastScreenshotAt!)} ago.',
      );
      return;
    }

    _screenshotInProgress = true;
    _lastScreenshotAt = now;

    try {
      Uint8List? bytes;
      final agentToken = await _secureStorage.readAccessToken() ?? 'unknown';
      const channel = 'screenshot';
      final agentId = await _secureStorage.readAgentId() ?? 'unknown_user';

      final nowTs = DateTime.now();
      final date =
          '${nowTs.year.toString().padLeft(4, '0')}-'
          '${nowTs.month.toString().padLeft(2, '0')}-'
          '${nowTs.day.toString().padLeft(2, '0')}';
      final time =
          '${nowTs.hour.toString().padLeft(2, '0')}-'
          '${nowTs.minute.toString().padLeft(2, '0')}-'
          '${nowTs.second.toString().padLeft(2, '0')}';

      final filename = 'scr_ss_${agentId}_${date}_$time.png';

      // macOS
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final allowed = await ScreenCapturer.instance.isAccessAllowed();
        if (!allowed) {
          await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
          logger.warn('[Screenshot] macOS permission not granted.');
          return;
        }

        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/$filename';

        final capture = await ScreenCapturer.instance.capture(
          mode: CaptureMode.screen,
          copyToClipboard: false,
          silent: true,
          imagePath: path,
        );

        if (capture == null) {
          logger.warn('[Screenshot] macOS capture returned null.');
          return;
        }

        final file = File(path);
        if (!await file.exists()) {
          logger.warn('[Screenshot] file not found: $path');
          return;
        }
        bytes = await file.readAsBytes();
      }
      // Windows
      else if (defaultTargetPlatform == TargetPlatform.windows) {
        final controller = DesktopScreenshot();
        final image = await controller.getScreenshot();
        if (image == null || image.isEmpty) {
          logger.warn('[Screenshot] Windows capture failed.');
          return;
        }
        bytes = image;
      } else {
        logger.warn(
          '[Screenshot] Unsupported platform: $defaultTargetPlatform',
        );
        return;
      }

      if (bytes.isEmpty) {
        logger.warn('[Screenshot] bytes empty, skipping upload.');
        return;
      }

      final uri = Uri.parse(
        '$baseUrl/api/storage/file/$agentId/upload',
      ).replace(
        queryParameters: {
          'channel': channel,
          'access_token': agentToken,
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
        logger.info('[Screenshot] uploaded: $filename');
      } else {
        logger.error(
          '[Screenshot] upload failed: ${response.statusCode} ${response.body}',
        );
      }
    } catch (e, st) {
      logger.error('[Screenshot] error during screenshot():', e, st);
    } finally {
      _screenshotInProgress = false;
    }
  }
}
