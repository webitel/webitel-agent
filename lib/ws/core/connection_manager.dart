import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/logger/logger.dart';

typedef ChannelConnector = WebSocketChannel Function(Uri uri);

class WsConnectionManager {
  // Without pings a half-open TCP connection (VPN drop, PC sleep, NAT timeout)
  // looks connected for hours while no events arrive.
  static const pingInterval = Duration(seconds: 20);

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Future<void>? _connecting;

  bool _isConnected = false;
  bool _isDisposed = false;
  int _retryCount = 0;
  int _generation = 0;

  final void Function(dynamic message) onMessage;
  final void Function() onDisconnected;
  final ChannelConnector _connector;

  WsConnectionManager({
    required this.onMessage,
    required this.onDisconnected,
    ChannelConnector? connector,
  }) : _connector =
           connector ??
           ((uri) =>
               IOWebSocketChannel.connect(uri, pingInterval: pingInterval));

  bool get isConnected => _isConnected;

  // Changes with every new channel, so a caller can drop only the connection
  // it established and not a newer one.
  int get generation => _generation;

  Future<void> get ready async {
    if (_isDisposed || _isConnected) return;
    await _connecting;
  }

  Future<void> connect(String url) {
    if (_isConnected) return Future.value();
    _isDisposed = false;
    final inFlight = _connecting;
    if (inFlight != null) return inFlight;

    late final Future<void> attempt;
    attempt = _connect(url).whenComplete(() {
      if (identical(_connecting, attempt)) _connecting = null;
    });
    _connecting = attempt;
    return attempt;
  }

  Future<void> _connect(String url) async {
    logger.info('[WS_CONN] ATTEMPT_CONNECT: $url');
    final channel = _connector(Uri.parse(url));
    _channel = channel;
    _generation++;

    _subscription = channel.stream.listen(
      (msg) {
        if (!identical(_channel, channel)) return;
        _retryCount = 0;
        logger.debug('[WS_CONN] RECEIVE_RAW: $msg');
        onMessage(msg);
      },
      onError: (err) {
        logger.error('[WS_CONN] STREAM_ERROR: $err');
        _handleDisconnect('STREAM_ERROR', channel);
      },
      onDone: () {
        logger.warn('[WS_CONN] CLOSED');
        _handleDisconnect('SERVER_CLOSED', channel);
      },
      cancelOnError: true,
    );

    try {
      await channel.ready;
    } catch (e, st) {
      logger.error('[WS_CONN] CONNECT_ERROR: $e', e, st);
      _handleDisconnect('CONNECT_FAILED', channel);
      rethrow;
    }

    if (_isDisposed || !identical(_channel, channel)) {
      channel.sink.close();
      throw StateError('Connection was closed while it was being established');
    }

    _isConnected = true;
    logger.info('[WS_CONN] ESTABLISHED');
  }

  void send(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return;

    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      logger.error('[WS_CONN] WRITE_ERROR: $e');
      _handleDisconnect('WRITE_ERROR', _channel);
    }
  }

  void drop(String reason) => _handleDisconnect(reason, _channel);

  void _handleDisconnect(String reason, WebSocketChannel? channel) {
    if (channel == null || !identical(_channel, channel)) return;

    logger.warn('[WS_CONN] DISCONNECTED | $reason');

    _isConnected = false;
    // The attempt that owned this channel is dead; the next connect() starts a new one.
    _connecting = null;

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
    _handleDisconnect('DISPOSED', _channel);
  }
}
