import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/storage/storage.dart';

class AgentControlService {
  final String baseUrl;
  final _secureStorage = SecureStorageService();

  bool _screenControlEnabled = false;
  Timer? _timer;

  AgentControlService({required this.baseUrl});

  bool get screenControlEnabled => _screenControlEnabled;

  void start() {
    _fetchScreenControl();
    _timer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _fetchScreenControl(),
    );
  }

  void stop() {
    _timer?.cancel();
  }

  Future<void> _fetchScreenControl() async {
    try {
      final token = await _secureStorage.readAccessToken();
      final agentId = await _secureStorage.readAgentId();

      if (token == null || agentId == null) {
        logger.warn('[Control] Missing token or agentId.');
        return;
      }

      final uri = Uri.parse(
        '$baseUrl/api/call_center/agents?page=1&size=1&fields=screen_control&id=$agentId',
      );

      final resp = await http.get(uri, headers: {'X-Webitel-Access': token});

      if (resp.statusCode == 200) {
        final js = jsonDecode(resp.body);
        final items = js['items'];
        if (items is List && items.isNotEmpty) {
          final dynamic scValue = items.first['screen_control'];
          final enabled = scValue == true;

          if (_screenControlEnabled != enabled) {
            _screenControlEnabled = enabled;
            logger.info('[Control] screen_control changed: $enabled');
          }
        } else {
          logger.warn('[Control] Empty agents list.');
        }
      } else {
        logger.warn('[Control] Failed to fetch: ${resp.statusCode}');
      }
    } catch (e, st) {
      logger.error('[Control] fetch error:', e, st);
    }
  }
}
