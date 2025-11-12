import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/storage/storage.dart';

class TokenWatcher {
  final String baseUrl;
  final Future<void> Function() onExpired;

  final _storage = SecureStorageService();
  Timer? _timer;
  bool _running = false;

  TokenWatcher({required this.baseUrl, required this.onExpired});

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    _check();
  }

  Future<void> _check() async {
    final token = await _storage.readAccessToken();
    if (token == null || token.isEmpty) await onExpired();

    try {
      final uri = Uri.parse('$baseUrl/api/userinfo');
      final resp = await http.get(
        uri,
        headers: {'X-Webitel-Access': token ?? ''},
      );
      if (resp.statusCode == 401) {
        logger.warn(
          '[TokenWatcher] Token expired (401). Triggering onExpired.',
        );
        await onExpired();
        return;
      }

      final body = jsonDecode(resp.body);
      final exp = int.tryParse(body['expires_at']?.toString() ?? '');
      if (exp != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (exp - now < 60 * 1000 * 10) {
          // less than 10 minutes to expire
          logger.warn(
            '[TokenWatcher] Token nearing expiration. Triggering onExpired.',
          );
          await onExpired();
        }
      }
    } catch (e, st) {
      logger.warn('[TokenWatcher] check failed: $e\n$st');
    }
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }
}
