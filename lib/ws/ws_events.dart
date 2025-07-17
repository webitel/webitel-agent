enum WebSocketEvent { agentStatus, hello, call, notification, unknown }

WebSocketEvent fromString(String? value) {
  switch (value) {
    case 'agent_status':
      return WebSocketEvent.agentStatus;
    case 'hello':
      return WebSocketEvent.hello;
    case 'call':
      return WebSocketEvent.call;
    case 'notification':
      return WebSocketEvent.notification;
    default:
      return WebSocketEvent.unknown;
  }
}
