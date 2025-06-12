// lib/services/secure_storage_service.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A singleton service for FlutterSecureStorage to ensure
/// a single instance across the application.
class SecureStorageService {
  // Private constructor to prevent direct instantiation
  SecureStorageService._internal();

  // The single instance of the class
  static final SecureStorageService _instance =
      SecureStorageService._internal();

  /// Factory constructor to return the same instance every time
  factory SecureStorageService() {
    return _instance;
  }

  /// The FlutterSecureStorage instance itself
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Expose the FlutterSecureStorage instance if needed
  FlutterSecureStorage get storage => _storage;

  // --- Convenience methods for common operations ---
  // You can add more specific methods for different keys if your app grows

  /// Writes the access token to secure storage.
  Future<void> writeAccessToken(String token) async {
    await _storage.write(key: 'token', value: token);
  }

  /// Reads the access token from secure storage.
  Future<String?> readAccessToken() async {
    return await _storage.read(key: 'token');
  }

  /// Deletes the access token from secure storage.
  Future<void> deleteAccessToken() async {
    await _storage.delete(key: 'token');
  }

  /// Writes the agent ID (as a String) to secure storage.
  Future<void> writeAgentId(int agentId) async {
    await _storage.write(key: 'agent_id', value: agentId.toString());
  }

  /// Reads the agent ID from secure storage. Returns null if not found.
  Future<int?> readAgentId() async {
    final idStr = await _storage.read(key: 'agent_id');
    if (idStr == null) return null;
    return int.tryParse(idStr);
  }

  /// Deletes the agent ID from secure storage.
  Future<void> deleteAgentId() async {
    await _storage.delete(key: 'agent_id');
  }
}
