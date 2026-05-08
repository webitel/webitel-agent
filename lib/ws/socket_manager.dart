import 'dart:async';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'webitel_socket.dart';
import 'core/config.dart';
import '../core/logger/logger.dart';

class SocketManager {
  final String baseUrl;
  final String wsUrl;
  final String token;
  final IStorageService storage;

  WebitelSocket? _socket;

  SocketManager({
    required this.baseUrl,
    required this.wsUrl,
    required this.token,
    required this.storage,
  });

  /// [LOGIC] Lazy initialization of the socket singleton instance
  WebitelSocket get socket {
    _socket ??= WebitelSocket(
      config: WebitelSocketConfig(url: wsUrl, baseUrl: baseUrl, token: token),
      storage: storage,
    );
    return _socket!;
  }

  /// [LOGIC] Safe connection sequence with redundancy guards.
  /// [GUARD] Sequential execution: connect -> wait for ready -> authenticate.
  Future<bool> connectAndAuthenticate() async {
    try {
      final ws = socket;

      logger.info('[SOCKET_MGR] Starting connection sequence...');

      // 1. [GUARD] Establish physical connection
      await ws.connect();

      // 2. [GUARD] Wait for the stream to be fully operational
      // This ensures 'isConnected' is true before we proceed to auth
      await ws.ready.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Socket ready timeout reached'),
      );

      // 3. [LOGIC] Perform logical authentication (hello handshake)
      await ws.authenticate();

      logger.info('[SOCKET_MGR] Connection lifecycle verified.');
      return true;
    } catch (e, st) {
      logger.error('[SOCKET_MGR] LifeCycle Error', e, st);
      return false;
    }
  }

  /// [GUARD] Graceful shutdown of the socket connection
  Future<void> disconnect() async {
    try {
      await _socket?.disconnect();
    } finally {
      _socket = null;
    }
  }
}
