import 'package:flutter/material.dart';
import 'package:webitel_desk_track/app/initializer.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/webview/login.dart';

class LoginService {
  /// Presents login WebView and returns true if login succeeded.
  static Future<bool> performLogin() async {
    try {
      final navigator = navigatorKey.currentState;
      if (navigator == null) {
        logger.error('[LoginService] NavigatorState not available.');
        return false;
      }

      final result = await navigator.push<bool>(
        MaterialPageRoute(
          builder: (_) => LoginWebView(url: AppConfig.instance.loginUrl),
        ),
      );

      if (result == true) {
        final token = await SecureStorageService().readAccessToken();
        final ok = token != null && token.isNotEmpty;
        logger.info('[LoginService] Login result: $ok');
        return ok;
      }

      logger.info('[LoginService] Login cancelled or failed.');
      return false;
    } catch (e, st) {
      logger.error('[LoginService] Login error:', e, st);
      return false;
    }
  }
}
