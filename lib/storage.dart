import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SecureStorageService {
  SecureStorageService._internal();

  static final SecureStorageService _instance =
      SecureStorageService._internal();

  factory SecureStorageService() => _instance;

  /// Writes the access token to storage (plain text).
  Future<void> writeAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
  }

  /// Reads the access token from storage (plain text).
  Future<String?> readAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('token');
  }

  /// Deletes the access token from storage.
  Future<void> deleteAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }

  /// Writes the agent ID (not encrypted).
  Future<void> writeAgentId(int agentId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('agent_id', agentId);
  }

  /// Reads the agent ID (not encrypted).
  Future<int?> readAgentId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('agent_id');
  }

  /// Deletes the agent ID.
  Future<void> deleteAgentId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('agent_id');
  }
}
