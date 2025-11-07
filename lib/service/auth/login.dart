// lib/service/auth/login_service.dart
import 'package:flutter/material.dart';
import 'package:webitel_desk_track/app/initializer.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/webview/login.dart';

/// Handles login flow via the WebView screen.
/// This class intentionally avoids holding UI state and is fully static.
class LoginService {
  static bool _isLoggingIn = false;

  /// Presents login WebView and returns true if login succeeded.
  static Future<bool> performLogin() async {
    if (_isLoggingIn) {
      logger.warn('[LoginService] Login already in progress, skipping.');
      return false;
    }
    _isLoggingIn = true;

    try {
      // Use the navigator from AppInitializer's app. Ensure it exists.
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
    } finally {
      _isLoggingIn = false;
    }
  }
}
