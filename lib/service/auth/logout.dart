import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/storage/storage.dart';

class LogoutService {
  Future<void> logout() async {
    try {
      final storage = SecureStorageService();
      final token = await storage.readAccessToken();

      if (token == null || token.isEmpty) {
        logger.warn('LogoutService: No token found, skipping logout request.');
        return;
      }

      final url = Uri.parse('${AppConfig.instance.baseUrl}/api/logout');

      final response = await http.post(
        url,
        headers: {
          'X-Webitel-Access': token,
          'Content-Type': 'application/json',
        },
      );

      logger.info('LogoutService: response ${response.statusCode}');
      if (response.statusCode == 200) {
        logger.info('LogoutService: logout successful  ${response.statusCode}');
      } else {
        logger.warn(
          'LogoutService: unexpected response ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e, s) {
      logger.error('LogoutService: logout failed', e, s);
    }
  }
}
