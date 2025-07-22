import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  AppConfig._();

  static String get loginUrl =>
      dotenv.env['LOGIN_URL'] ?? 'https://dev.webitel.com/';

  static bool get screenshotEnabled {
    final val = dotenv.env['SCREENSHOT_ENABLED'] ?? 'false';
    return val.toLowerCase() == 'true';
  }

  static String get mediaUploadUrl {
    return dotenv.env['MEDIA_UPLOAD_URL'] ?? 'https://dev.webitel.com';
  }

  static String get webitelWsUrl {
    return dotenv.env['WEBITEL_WS_URL'] ?? 'wss://dev.webitel.com/ws/websocket';
  }

  static bool get logToFile {
    final val = dotenv.env['LOG_TO_FILE'] ?? 'false';
    return val.toLowerCase() == 'true';
  }

  static String get logFilePath {
    return dotenv.env['LOG_FILE_PATH'] ?? 'logs/app.log';
  }

  static String get webrtcSdpUrl {
    return dotenv.env['WEBRTC_SDP_URL'] ??
        'https://dev.webitel.com/api/storage/p2p/upload/video?channel=call';
  }

  static List<Map<String, dynamic>> get webrtcIceServers {
    final raw = dotenv.env['WEBRTC_ICE_SERVERS'];
    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> decoded = jsonDecode(raw);
      return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      return [];
    }
  }

  static int get videoWidth {
    return int.tryParse(dotenv.env['VIDEO_WIDTH'] ?? '') ?? 1280;
  }

  static int get videoHeight {
    return int.tryParse(dotenv.env['VIDEO_HEIGHT'] ?? '') ?? 720;
  }

  static int get videoFramerate {
    return int.tryParse(dotenv.env['VIDEO_FRAMERATE'] ?? '') ?? 25;
  }
}
