import 'package:flutter/material.dart';
import 'package:webitel_desk_track/app/initializer.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/webview/login.dart';

class LoginService {
  final IStorageService _storage;

  LoginService({required IStorageService storage}) : _storage = storage;

  /// Presents login WebView and returns true if login succeeded.
  /// Uses the injected storage to verify the token after WebView close.
  Future<bool> performLogin() async {
    try {
      final navigator = navigatorKey.currentState;
      if (navigator == null) {
        logger.error(
          '[LoginService] NavigatorState not available. Check navigatorKey initialization.',
        );
        return false;
      }

      logger.info(
        '[LoginService] Opening Login WebView: ${AppConfig.instance.loginUrl}',
      );

      // Push the login screen and wait for the result
      final result = await navigator.push<bool>(
        MaterialPageRoute(
          builder:
              (_) => LoginWebView(
                url: AppConfig.instance.loginUrl,
                storage: _storage, // INJECTING STORAGE HERE - Fixes the error
              ),
        ),
      );

      // If WebView returned true, we verify if the token was actually saved
      if (result == true) {
        final token = await _storage.readAccessToken();
        final isValid = token != null && token.isNotEmpty;

        if (isValid) {
          logger.info('[LoginService] Login successful. Token obtained.');
          return true;
        } else {
          logger.warn(
            '[LoginService] WebView reported success, but no token found in storage.',
          );
          return false;
        }
      }

      logger.info(
        '[LoginService] Login flow cancelled by user or failed in WebView.',
      );
      return false;
    } catch (e, st) {
      logger.error('[LoginService] Unexpected error during login flow', e, st);
      return false;
    }
  }
}
