import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';

class LogoutService {
  final IStorageService _storage;

  LogoutService({required IStorageService storage}) : _storage = storage;

  /// Performs a global logout: notifies the server and clears local storage.
  Future<void> logout() async {
    try {
      final token = await _storage.readAccessToken();

      if (token == null || token.isEmpty) {
        logger.warn(
          '[LogoutService] No token found in storage. Cleaning up locally anyway.',
        );
        await _storage.flush();
        return;
      }

      final url = Uri.parse('${AppConfig.instance.baseUrl}/api/logout');

      // 1. Notify the server about session termination
      final response = await http
          .post(
            url,
            headers: {
              'X-Webitel-Access': token,
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 5));

      logger.info('[LogoutService] Server response: ${response.statusCode}');

      if (response.statusCode != 200) {
        logger.warn(
          '[LogoutService] Server returned non-200 status: ${response.statusCode}. Body: ${response.body}',
        );
      }
    } catch (e, s) {
      // We log the error but proceed to clear local data
      // to ensure the user isn't "stuck" in a logged-in state.
      logger.error(
        '[LogoutService] Remote logout failed, proceeding with local cleanup',
        e,
        s,
      );
    } finally {
      // 2. ALWAYS clear local storage at the end
      await _storage.flush();
      logger.info('[LogoutService] Local storage flushed. Logout complete.');
    }
  }
}
