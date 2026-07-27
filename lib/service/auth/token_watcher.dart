import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';

/// Background service that periodically validates the access token.
/// Triggers [onExpired] callback if the token is invalid or nearing expiration.
class TokenWatcher {
  final String baseUrl;
  final Future<void> Function() onExpired;
  final IStorageService _storage;

  Timer? _timer;
  bool _isRunning = false;
  bool _isChecking = false;

  TokenWatcher({
    required this.baseUrl,
    required this.onExpired,
    required IStorageService storage,
  }) : _storage = storage;

  /// Starts the periodic check every 30 seconds.
  void start() {
    if (_isRunning) return;
    _isRunning = true;

    // Initial check and start periodic timer
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    _check();

    logger.info('[TokenWatcher] Service started.');
  }

  /// Stops the periodic check and cleans up resources.
  void stop() {
    _isRunning = false;
    _timer?.cancel();
    _timer = null;
    logger.info('[TokenWatcher] Service stopped.');
  }

  Future<void> _check() async {
    // Prevent overlapping checks if a request is slow
    if (_isChecking) return;
    _isChecking = true;

    try {
      final token = await _storage.readAccessToken();

      if (token == null || token.isEmpty) {
        logger.warn(
          '[TokenWatcher] No token found in storage. Requesting re-login.',
        );
        await _triggerExpired();
        return;
      }

      final uri = Uri.parse('$baseUrl/api/userinfo');
      final resp = await http
          .get(uri, headers: {'X-Webitel-Access': token})
          .timeout(const Duration(seconds: 10));

      // Only react to hard expiration. Re-login through the WebView reuses the
      // still-valid server SSO session and returns the same non-renewed token,
      // so a proactive "nearing expiration" trigger loops forever until the
      // token actually dies.
      if (resp.statusCode == 401) {
        logger.warn('[TokenWatcher] Token expired (401).');
        await _triggerExpired();
      }
    } catch (e) {
      // We use warn instead of error to avoid spamming logs on transient network issues
      logger.warn('[TokenWatcher] Validation request failed: $e');
    } finally {
      _isChecking = false;
    }
  }

  /// Safely stops the watcher and triggers the expiration callback.
  Future<void> _triggerExpired() async {
    stop(); // Stop the timer first to avoid duplicate triggers
    await onExpired();
  }
}
