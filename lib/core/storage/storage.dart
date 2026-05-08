import 'package:shared_preferences/shared_preferences.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';

class SharedPrefsService implements IStorageService {
  // Singleton instance
  static final SharedPrefsService _instance = SharedPrefsService._internal();

  // Private constructor
  SharedPrefsService._internal();

  // Factory constructor for global access
  factory SharedPrefsService() => _instance;

  // Keys as constants to avoid typos
  static const String _tokenKey = 'access_token';
  static const String _agentIdKey = 'agent_id';

  /// Helper to get SharedPreferences instance
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<void> writeAccessToken(String token) async {
    final p = await _prefs;
    await p.setString(_tokenKey, token);
  }

  @override
  Future<String?> readAccessToken() async {
    final p = await _prefs;
    return p.getString(_tokenKey);
  }

  @override
  Future<void> deleteAccessToken() async {
    final p = await _prefs;
    await p.remove(_tokenKey);
  }

  @override
  Future<void> writeAgentId(int agentId) async {
    final p = await _prefs;
    await p.setInt(_agentIdKey, agentId);
  }

  @override
  Future<int?> readAgentId() async {
    final p = await _prefs;
    return p.getInt(_agentIdKey);
  }

  @override
  Future<void> deleteAgentId() async {
    final p = await _prefs;
    await p.remove(_agentIdKey);
  }

  @override
  Future<void> flush() async {
    final p = await _prefs;
    await p.clear();
  }
}
