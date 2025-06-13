import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  AppConfig._();

  static String get loginUrl =>
      dotenv.env['LOGIN_URL'] ?? 'https://dev.webitel.com/';

  static bool get screenshotEnabled {
    final val = dotenv.env['SCREENSHOT_ENABLED'] ?? 'false';
    return val.toLowerCase() == 'true';
  }

  static int get screenshotPeriodicitySec {
    return int.tryParse(dotenv.env['SCREENSHOT_PERIODICITY_SEC'] ?? '') ?? 90;
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
}
