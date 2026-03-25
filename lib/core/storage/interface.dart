abstract class IStorageService {
  /// Save the session token to persistent storage.
  Future<void> writeAccessToken(String token);

  /// Retrieve the session token from persistent storage.
  Future<String?> readAccessToken();

  /// Remove the session token from persistent storage.
  Future<void> deleteAccessToken();

  /// Save the agent's unique identifier.
  Future<void> writeAgentId(int agentId);

  /// Retrieve the agent's unique identifier.
  Future<int?> readAgentId();

  /// Remove the agent's unique identifier.
  Future<void> deleteAgentId();

  /// Clear all data stored by this service.
  Future<void> flush();
}
