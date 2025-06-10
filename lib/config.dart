import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  // Private constructor to prevent instantiation
  AppConfig._();

  static String get loginUrl {
    return dotenv.env['LOGIN_URL'] ?? 'https://dev.webitel.com/';
  }
}
