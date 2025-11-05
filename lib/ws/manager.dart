// lib/service/socket/socket_manager.dart
import 'dart:async';
import 'dart:ui';

import 'package:webitel_agent_flutter/ws/ws.dart';
import 'package:webitel_agent_flutter/ws/ws_config.dart';
import 'package:webitel_agent_flutter/core/logger.dart';
import 'package:webitel_agent_flutter/service/control/agent_control.dart';

/// Thin manager around WebitelSocket to centralize connect/auth handling.
class SocketManager {
  final String baseUrl;
  final String wsUrl;
  String token;

  WebitelSocket? _socket;
  AgentControlService? _agentControlService;

  VoidCallback? onAuthenticationFailed; // assigned by AppFlow

  SocketManager({
    required this.baseUrl,
    required this.wsUrl,
    required this.token,
  });

  WebitelSocket get socket {
    if (_socket == null) {
      throw StateError('Socket not initialized');
    }
    return _socket!;
  }

  /// Connect and authenticate. Returns true if both succeed.
  Future<bool> connectAndAuthenticate() async {
    try {
      _socket = WebitelSocket(
        config: WebitelSocketConfig(url: wsUrl, baseUrl: baseUrl, token: token),
        agentControlService: AgentControlService(baseUrl: baseUrl),
      );

      _socket!.onAuthenticationFailed = () {
        if (onAuthenticationFailed != null) onAuthenticationFailed!();
      };

      await _socket!.connect();
      await _socket!.authenticate();

      logger.info('[SocketManager] Connected and authenticated');

      return true;
    } catch (e, st) {
      logger.error('[SocketManager] connect/auth failed: $e\n$st');
      return false;
    }
  }

  void updateToken(String newToken) {
    token = newToken;
    _socket?.updateToken(newToken);
  }

  Future<void> disconnect() async {
    try {
      await _socket?.disconnect();
      _socket = null;
    } catch (e, st) {
      logger.warn('[SocketManager] disconnect error: $e\n$st');
    }
  }
}
