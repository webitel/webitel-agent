// [CORE] WebSocket Event and Action Definitions
enum WebSocketEvent { agentStatus, hello, call, notification, channel, unknown }

enum NotificationAction {
  screenShare,
  screenshot,
  screenRecordStart,
  screenRecordStop,
  unknown;

  factory NotificationAction.fromString(String? value) {
    switch (value) {
      case 'screen_share':
        return NotificationAction.screenShare;
      case 'screenshot':
        return NotificationAction.screenshot;
      case 'ss_record_start':
        return NotificationAction.screenRecordStart;
      case 'ss_record_stop':
        return NotificationAction.screenRecordStop;
      default:
        return NotificationAction.unknown;
    }
  }
}

class SocketActions {
  // [AUTH] Authentication actions
  static const authenticationChallenge = 'authentication_challenge';
  static const agentSession = 'cc_agent_session';
  static const ack = 'ss_ack';

  // [CALLS] Call-related requests
  static const callByUser = 'call_by_user';

  static const ping = 'ping';
}

WebSocketEvent eventFromString(String? value) {
  switch (value) {
    case 'agent_status':
      return WebSocketEvent.agentStatus;
    case 'hello':
      return WebSocketEvent.hello;
    case 'call':
      return WebSocketEvent.call;
    case 'notification':
      return WebSocketEvent.notification;
    case 'channel':
      return WebSocketEvent.channel;
    default:
      return WebSocketEvent.unknown;
  }
}
