import 'dart:async';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'webitel_socket.dart';
import 'core/config.dart';
import 'core/error.dart';
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

  // Throws AuthRejectedException when the token is refused; any other failure
  // means the server is unreachable for now.
  Future<void> connectAndAuthenticate() async {
    final ws = socket;
    logger.info('[SOCKET_MGR] Starting connection sequence...');
    try {
      await ws.connect();
      await ws.authenticate();
    } on AuthRejectedException {
      rethrow;
    } on SocketUnavailableException {
      rethrow;
    } catch (e) {
      throw SocketUnavailableException(e.toString());
    }
    logger.info('[SOCKET_MGR] Connection lifecycle verified.');
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
