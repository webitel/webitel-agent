import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';

import 'logger.dart';

class ScreenshotSenderService {
  final String uploadUrl;
  final Duration interval;

  Timer? _timer;
  bool _isRunning = false;

  final _logger = LoggerService();

  ScreenshotSenderService({required this.uploadUrl, Duration? interval})
    : interval =
          interval ??
          Duration(
            seconds:
                int.tryParse(dotenv.env['SCREENSHOT_PERIODICITY_SEC'] ?? '') ??
                90,
          );

  void start() {
    if (_isRunning) return;
    _isRunning = true;

    _timer = Timer.periodic(interval, (_) => _takeAndSend());
    _takeAndSend(); // Immediate first screenshot
  }

  void stop() {
    _timer?.cancel();
    _isRunning = false;
  }

  Future<void> _takeAndSend() async {
    try {
      // macOS: Check and request screen capture access
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final allowed = await ScreenCapturer.instance.isAccessAllowed();
        if (!allowed) {
          await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
          _logger.warn('Screen capture access not yet granted.');
          return;
        }
      }

      // Get a writable directory for temporary files
      final directory = await getTemporaryDirectory();
      final filename = '${DateTime.now().toIso8601String()}.png';
      final fullPath = '${directory.path}/$filename';

      // Capture screenshot, save to file
      final capture = await ScreenCapturer.instance.capture(
        mode: CaptureMode.screen,
        copyToClipboard: false,
        silent: false,
        imagePath: fullPath,
      );

      if (capture == null) {
        _logger.warn('Capture returned null.');
        return;
      }

      // Read bytes from saved file
      final file = File(fullPath);
      if (!await file.exists()) {
        _logger.warn('Screenshot file does not exist at $fullPath');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _logger.warn('Screenshot file is empty.');
        return;
      }

      // Prepare upload URL with filename param
      final uri = Uri.parse('$uploadUrl&name=$filename');

      // Send HTTP POST with image bytes
      final http.Response res = await http.post(
        uri,
        headers: {'Content-Type': 'image/png'},
        body: bytes,
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        _logger.info('Screenshot uploaded: $filename');
      } else {
        _logger.error('Upload failed: ${res.statusCode} — ${res.body}');
      }
    } catch (e, stack) {
      _logger.error('Screenshot capture/upload failed: $e\n$stack');
    }
  }
}
