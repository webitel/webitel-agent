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

  // Runs every 3 minutes to fetch screen_control + interval
  Timer? _checkerTimer;

  // Timer that triggers actual screenshot uploads with configured interval
  Timer? _screenshotTimer;

  // Current values
  bool _serviceStarted = false;
  bool _screenControlEnabled = false; // from agents endpoint
  Duration _screenshotInterval = const Duration(minutes: 30); // default

  final _secureStorage = SecureStorageService();

  ScreenshotSenderService({required this.baseUrl});

  /// Start the background checker (every 3 minutes).
  /// This does NOT necessarily start screenshots — that depends on screen_control.
  void start() {
    if (_serviceStarted) return;
    _serviceStarted = true;

    // Run immediately, then every 3 minutes
    _fetchControlsAndInterval();
    _checkerTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _fetchControlsAndInterval(),
    );
  }

  /// Stop everything
  void stop() {
    _checkerTimer?.cancel();
    _screenshotTimer?.cancel();
    _serviceStarted = false;
    _screenControlEnabled = false;
  }

  Future<void> _fetchControlsAndInterval() async {
    try {
      final token = await _secureStorage.readAccessToken();
      int? agentId = await _secureStorage.readAgentId();

      switch ((token == null, agentId == null)) {
        case (true, _):
          logger.warn('[Screenshot] Missing token → skipping fetch.');
          return;

        case (_, true):
          logger.warn(
            '[Screenshot] Missing agentId → trying to fetch via WebSocket...',
          );
          try {
            final socket = WebitelSocket.instance;
            final session = await socket.getAgentSession();
            agentId = session.agentId;
            await _secureStorage.writeAgentId(agentId);
            await _fetchControlsAndInterval();
            logger.info('[Screenshot] agentId restored from session: $agentId');
          } catch (e, st) {
            logger.error(
              '[Screenshot] Failed to recover agentId via socket:',
              e,
              st,
            );
            return;
          }
          break;

        default:
          break;
      }

      // Fetch screen_control
      final agentsUri = Uri.parse(
        '$baseUrl/api/call_center/agents?page=1&size=1&fields=screen_control&id=$agentId',
      );

      final agentsResp = await http.get(
        agentsUri,
        headers: {'X-Webitel-Access': token ?? ''},
      );
      if (agentsResp.statusCode == 200) {
        final js = jsonDecode(agentsResp.body);
        final items = js['items'];
        if (items is List && items.isNotEmpty) {
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
        } else {
          logger.warn('[Screenshot] agents response missing items or empty.');
        }
      } else {
        logger.warn(
          '[Screenshot] agents fetch failed: ${agentsResp.statusCode} ${agentsResp.body}',
        );
      }

      // Fetch screenshot_interval
      final settingsUri = Uri.parse(
        '$baseUrl/api/settings?name=screenshot_interval',
      );

      final settingsResp = await http.get(
        settingsUri,
        headers: {'X-Webitel-Access': token ?? ''},
      );
      if (settingsResp.statusCode == 200) {
        final js = jsonDecode(settingsResp.body);
        final items = js['items'];
        if (items is List && items.isNotEmpty) {
          final value = items.first['value'];
          final minutes = int.tryParse(value.toString());
          if (minutes != null && minutes > 0) {
            final newInterval = Duration(minutes: minutes);
            if (newInterval != _screenshotInterval) {
              logger.info(
                '[Screenshot] interval updated from $_screenshotInterval to $newInterval',
              );
              _screenshotInterval = newInterval;
              // if screenshots are running, restart with new interval
              if (_screenControlEnabled) {
                _restartScreenshotTimer();
              }
            }
          } else {
            logger.warn(
              '[Screenshot] invalid screenshot_interval value: $value',
            );
          }
        } else {
          logger.warn('[Screenshot] settings response missing items or empty.');
        }
      } else {
        logger.warn(
          '[Screenshot] settings fetch failed: ${settingsResp.statusCode} ${settingsResp.body}',
        );
      }
    } catch (e, st) {
      logger.error('[Screenshot] failed to fetch control/interval:', e, st);
    }
  }

  void _startScreenshotsIfNeeded() {
    if (!_screenControlEnabled) return;
    // If timer already running with correct interval — keep it
    if (_screenshotTimer != null && _screenshotTimer!.isActive) {
      // but if its period differs from _screenshotInterval, restart
      // Unfortunately Timer.periodic doesn't expose period — so we always restart to be safe
      _restartScreenshotTimer();
      return;
    }
    _restartScreenshotTimer();
  }

  void _restartScreenshotTimer() {
    _screenshotTimer?.cancel();
    _screenshotTimer = Timer.periodic(_screenshotInterval, (_) => screenshot());
    // take first shot immediately
    screenshot();
  }

  void _stopScreenshots() {
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
  }

  /// Captures a screenshot depending on the platform and uploads it to the server.
  Future<void> screenshot() async {
    try {
      Uint8List? bytes;
      final agentToken = await _secureStorage.readAccessToken() ?? 'unknown';
      const channel = 'screenshot';
      final agentId = await _secureStorage.readAgentId() ?? 'unknown_user';

      final now = DateTime.now();
      final date =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final time =
          '${now.hour.toString().padLeft(2, '0')}-'
          '${now.minute.toString().padLeft(2, '0')}-'
          '${now.second.toString().padLeft(2, '0')}';

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
      logger.error('[Screenshot] error:', e, st);
    }
  }
}
