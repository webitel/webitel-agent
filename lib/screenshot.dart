import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_screenshot/desktop_screenshot.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_agent_flutter/storage.dart';

import 'config/config.dart';
import 'logger.dart';

class ScreenshotSenderService {
  final String baseUrl;
  Timer? _timer;
  Duration _interval = const Duration(seconds: 10);
  bool _isRunning = false;

  final _secureStorage = SecureStorageService();

  ScreenshotSenderService({required this.baseUrl});

  void start() {
    if (_isRunning) return;
    _isRunning = true;

    _fetchIntervalAndStartTimer();
  }

  void stop() {
    _timer?.cancel();
    _isRunning = false;
  }

  Future<void> _fetchIntervalAndStartTimer() async {
    try {
      final token = await _secureStorage.readAccessToken();
      if (token == null) {
        logger.warn('No access token available for interval fetch.');
        return;
      }

      final uri = Uri.parse(
        '${AppConfig.instance.baseUrl}/api/settings?name=screenshot_interval',
      );
      final res = await http.get(uri, headers: {'X-Webitel-Access': token});

      if (res.statusCode == 200) {
        final bodyJson = jsonDecode(res.body);
        final items = bodyJson['items'];
        if (items is List && items.isNotEmpty) {
          final value = items.first['value'];
          final minutes = int.tryParse(value.toString());
          if (minutes != null && minutes > 0) {
            _interval = Duration(seconds: minutes * 60);
            logger.info('Fetched screenshot interval: $minutes minutes');
          } else {
            logger.warn('Invalid interval format: $value');
          }
        } else {
          logger.warn('No items in interval response: ${res.body}');
        }
      } else {
        logger.warn('Interval fetch failed: ${res.statusCode} — ${res.body}');
      }
    } catch (e, stack) {
      logger.error('Failed to fetch interval: $e\n$stack');
    }

    // Always start timer, even if API failed
    _timer = Timer.periodic(_interval, (_) => screenshot());
    screenshot(); // First run immediately
  }

  Future<void> screenshot() async {
    try {
      Uint8List? bytes;
      String filename =
          'screenshot-${DateTime.now().millisecondsSinceEpoch}.png';

      // -------------------------------
      // 🖥️ macOS — screen_capturer
      // -------------------------------
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final allowed = await ScreenCapturer.instance.isAccessAllowed();
        if (!allowed) {
          await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
          logger.warn('macOS screen capture permission not granted.');
          return;
        }

        final directory = await getTemporaryDirectory();
        final safeTimestamp = DateTime.now().toIso8601String().replaceAll(
          ':',
          '-',
        );
        final fullPath = '${directory.path}/$safeTimestamp.png';

        final capture = await ScreenCapturer.instance.capture(
          mode: CaptureMode.screen,
          copyToClipboard: false,
          silent: false,
          imagePath: fullPath,
        );

        if (capture == null) {
          logger.warn('Screenshot capture returned null.');
          return;
        }

        final file = File(fullPath);
        if (!await file.exists()) {
          logger.warn('Screenshot file not found at $fullPath');
          return;
        }

        bytes = await file.readAsBytes();
        filename = '$safeTimestamp.png';
      }
      // -------------------------------
      // 🪟 Windows — desktop_screenshot
      // -------------------------------
      else if (defaultTargetPlatform == TargetPlatform.windows) {
        final controller = DesktopScreenshot();
        final image = await controller.getScreenshot();
        if (image == null || image.isEmpty) {
          logger.warn('Windows screenshot failed (null or empty)');
          return;
        }
        bytes = image;
      } else {
        logger.warn('Unsupported platform: $defaultTargetPlatform');
        return;
      }

      if (bytes.isEmpty) {
        logger.warn('Screenshot bytes are empty.');
        return;
      }

      final agentId = await _secureStorage.readAgentId() ?? 'unknown_user';
      final agentToken = await _secureStorage.readAccessToken() ?? 'unknown';
      const channel = 'screenshot';

      final uri = Uri.parse(
        '$baseUrl/api/storage/file/$agentId/upload',
      ).replace(
        queryParameters: {
          'channel': channel,
          'access_token': agentToken,
          'thumbnail': 'true',
          'name': filename
        },
      );

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'image/png'},
        body: bytes,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        logger.info('Screenshot uploaded: $filename');
      } else {
        logger.error(
          'Screenshot upload failed: ${response.statusCode} — ${response.body}',
        );
        throw Exception(
          'Upload failed: ${response.statusCode} — ${response.body}',
        );
      }
    } catch (e, stack) {
      logger.error('Screenshot error: $e\n$stack');
      throw Exception('Screenshot error: $e\n$stack');
    }
  }
}
