import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/logger/logger.dart';

class WsConnectionManager {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Completer<void>? _connectionCompleter;

  bool _isConnected = false;
  bool _isDisposed = false;
  int _retryCount = 0;

  final void Function(dynamic message) onMessage;
  final void Function() onDisconnected;

  WsConnectionManager({required this.onMessage, required this.onDisconnected});

  bool get isConnected => _isConnected;

  Future<void> get ready async {
    if (_isDisposed) return;

    while (_connectionCompleter == null && !_isDisposed) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    await _connectionCompleter?.future;
    await _channel?.ready;
  }

  Future<void> connect(String url) async {
    if (_isConnected) return;

    _isDisposed = false;
    _connectionCompleter = Completer<void>();

    try {
      logger.info('[WS_CONN] ATTEMPT_CONNECT: $url');

      _channel = WebSocketChannel.connect(Uri.parse(url));

      _subscription = _channel!.stream.listen(
        (msg) {
          _retryCount = 0;
          logger.debug('[WS_CONN] RECEIVE_RAW: $msg');
          onMessage(msg);
        },
        onError: (err) {
          logger.error('[WS_CONN] STREAM_ERROR: $err');
          _handleDisconnect('STREAM_ERROR');
        },
        onDone: () {
          logger.warn('[WS_CONN] CLOSED');
          _handleDisconnect('SERVER_CLOSED');
        },
        cancelOnError: true,
      );

      _connectionCompleter?.complete();
      await _channel!.ready;

      _isConnected = true;
      logger.info('[WS_CONN] ESTABLISHED');
    } catch (e, st) {
      if (_connectionCompleter?.isCompleted == false) {
        _connectionCompleter?.completeError(e);
      }

      logger.error('[WS_CONN] CONNECT_ERROR: $e', e, st);
      _handleDisconnect('CONNECT_FAILED');
      rethrow;
    }
  }

  void send(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return;

    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      logger.error('[WS_CONN] WRITE_ERROR: $e');
      _handleDisconnect('WRITE_ERROR');
    }
  }

  void _handleDisconnect(String reason) {
    if (!_isConnected && _channel == null) return;

    logger.warn('[WS_CONN] DISCONNECTED | $reason');

    _isConnected = false;
    _connectionCompleter = null;

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
