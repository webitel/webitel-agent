// socket_constants.dart

enum AgentStatus {
  online,
  offline,
  pause,
  unknown,
}

class SocketActions {
  static const authenticationChallenge = 'authentication_challenge';
  static const agentSession = 'cc_agent_session';
  static const userDefaultDevice = 'user_default_device';
  static const agentOnline = 'cc_agent_online';
  static const agentOffline = 'cc_agent_offline';
  static const agentPause = 'cc_agent_pause';
}
