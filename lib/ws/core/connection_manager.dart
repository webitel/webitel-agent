import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/logger/logger.dart';

class WsConnectionManager {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  bool _isConnected = false;
  bool _isDisposed = false;
  int _retryCount = 0;

  final void Function(dynamic message) onMessage;
  final void Function() onDisconnected;

  WsConnectionManager({required this.onMessage, required this.onDisconnected});

  bool get isConnected => _isConnected;

  Future<void> get ready async {
    if (_channel == null) throw StateError('[WS_CONN] Call connect() first');
    await _channel!.ready;
  }

  Future<void> connect(String url) async {
    if (_isConnected || _isDisposed) return;

    try {
      logger.info('[WS_CONN] ATTEMPT_CONNECT: $url');

      _channel = WebSocketChannel.connect(Uri.parse(url));

      _subscription = _channel!.stream.listen(
        (msg) {
          _retryCount = 0;
          // [DEBUG] Full raw incoming message
          logger.debug('[WS_CONN] RECEIVE_RAW: $msg');
          onMessage(msg);
        },
        onError: (err) {
          logger.error('[WS_CONN] STREAM_ERROR: $err');
          _handleDisconnect('STREAM_ERROR: $err');
        },
        onDone: () {
          final int? closeCode = _channel?.closeCode;
          final String? closeReason = _channel?.closeReason;

          logger.warn(
            '[WS_CONN] CONNECTION_CLOSED | CloseCode: $closeCode | Reason: ${closeReason ?? "none"}',
          );

          _handleDisconnect('SERVER_CLOSED');
        },
        cancelOnError: true,
      );

      // Wait for the connection to be fully established
      await _channel!.ready;

      _isConnected = true;
      logger.info('[WS_CONN] ESTABLISHED: Handshake successful');
    } catch (e, stackTrace) {
      logger.error('[WS_CONN] CONNECTION_FATAL_ERROR: $e', e, stackTrace);
      _handleDisconnect('CONNECTION_FAILED: $e');
      rethrow;
    }
  }

  void send(Map<String, dynamic> payload) {
    if (_isConnected && _channel != null) {
      try {
        _channel!.sink.add(jsonEncode(payload));
      } catch (e) {
        _handleDisconnect('WRITE_ERROR');
      }
    }
  }

  void _handleDisconnect(String reason) {
    if (!_isConnected && _channel == null) return;

    logger.warn('[WS_CONN] DISCONNECTED | $reason');
    _isConnected = false;

    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;

    if (!_isDisposed) {
      onDisconnected();
    }
  }

  Duration getNextRetryDelay() {
    _retryCount++;
    if (_retryCount > 6) return const Duration(seconds: 30);
    return Duration(seconds: _retryCount * 2);
  }

  void dispose() {
    _isDisposed = true;
    _handleDisconnect('DISPOSED');
  }
}
