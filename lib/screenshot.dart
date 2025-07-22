import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_agent_flutter/storage.dart';

import 'config.dart';
import 'logger.dart';

class ScreenshotSenderService {
  final String uploadUrl;
  Timer? _timer;
  Duration _interval = const Duration(minutes: 5);
  bool _isRunning = false;

  final _logger = LoggerService();
  final _secureStorage = SecureStorageService();

  ScreenshotSenderService({required this.uploadUrl});

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
        _logger.warn('No access token available for interval fetch.');
        return;
      }

      final uri = Uri.parse(
        '${AppConfig.loginUrl}api/settings?name=screenshot_interval',
      );
      final res = await http.get(uri, headers: {'X-Webitel-Access': token});

      if (res.statusCode == 200) {
        final bodyJson = jsonDecode(res.body);
        final items = bodyJson['items'];
        if (items is List && items.isNotEmpty) {
          final value = items.first['value'];
          final minutes = int.tryParse(value.toString());
          if (minutes != null && minutes > 0) {
            _interval = Duration(minutes: minutes);
            _logger.info('Fetched screenshot interval: $minutes minutes');
          } else {
            _logger.warn('Invalid interval format: $value');
          }
        } else {
          _logger.warn('No items in interval response: ${res.body}');
        }
      } else {
        _logger.warn('Interval fetch failed: ${res.statusCode} — ${res.body}');
      }
    } catch (e, stack) {
      _logger.error('Failed to fetch interval: $e\n$stack');
    }

    // Always start timer, even if API failed
    _timer = Timer.periodic(_interval, (_) => _takeAndSend());
    _takeAndSend(); // First run immediately
  }

  Future<void> _takeAndSend() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final allowed = await ScreenCapturer.instance.isAccessAllowed();
        if (!allowed) {
          await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
          _logger.warn('macOS screen capture permission not granted.');
          return;
        }
      }

      final directory = await getTemporaryDirectory();
      final filename = '${DateTime.now().toIso8601String()}.png';
      final fullPath = '${directory.path}/$filename';

      final capture = await ScreenCapturer.instance.capture(
        mode: CaptureMode.screen,
        copyToClipboard: false,
        silent: false,
        imagePath: fullPath,
      );

      if (capture == null) {
        _logger.warn('Screenshot capture returned null.');
        return;
      }

      final file = File(fullPath);
      if (!await file.exists()) {
        _logger.warn('Screenshot file not found at $fullPath');
        return;
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _logger.warn('Screenshot file is empty.');
        return;
      }

      final uri = Uri.parse('$uploadUrl&name=$filename');
      final res = await http.post(
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
      _logger.error('Screenshot send failed: $e\n$stack');
    }
  }
}
