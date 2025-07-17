import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/webrtc/core/capturer.dart'
    show captureDesktopScreen;
import 'package:webitel_agent_flutter/webrtc/session/screen_streamer.dart';
import 'package:webitel_agent_flutter/ws/config.dart';
import 'package:webitel_agent_flutter/ws/constants.dart';
import 'package:webitel_agent_flutter/ws/model/agent.dart';
import 'package:webitel_agent_flutter/ws/model/auth.dart';
import 'package:webitel_agent_flutter/ws/model/user.dart';

import 'model/ws_error.dart';
import 'ws_events.dart';

enum AgentStatus { online, offline, pause, unknown }

class WebitelSocket {
  final WebitelSocketConfig config;

  late String _token;

  late WebSocketChannel _channel;
  late StreamSubscription _wsSubscription;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  final _agentStatusController = StreamController<AgentStatus>.broadcast();
  final _errorController = StreamController<SocketError>.broadcast();
  final _ackMessageController =
      StreamController<Map<String, dynamic>>.broadcast();

  final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};
  final _outgoingQueue = Queue<_QueuedRequest>();

  final logger = LoggerService();

  int _seq = 1;
  bool _isConnected = false;
  bool _isSending = false;

  void Function(String callId)? _onCallRinging;
  void Function(String callId)? _onCallHangup;
  void Function()? onAuthenticationFailed;

  ScreenStreamer? _screenCapturer;

  void Function(MediaStream stream)? onStreamReceived;

  void setOnScreenStream(void Function(MediaStream stream) callback) {
    onStreamReceived = callback;
  }

  WebitelSocket({required this.config}) {
    _token = config.token;
  }

  /// Public Streams
  Stream<AgentStatus> get agentStatusStream => _agentStatusController.stream;

  Stream<SocketError> get errorStream => _errorController.stream;

  /// Stream for "hello" acknowledgement messages
  Stream<Map<String, dynamic>> get ackMessageStream =>
      _ackMessageController.stream;

  void updateToken(String newToken) {
    _token = newToken;
    logger.info('WebitelSocket: Token updated.');
  }

  /// Connect and listen
  Future<void> connect() async {
    logger.info('WebitelSocket: Connecting to ${config.url}');
    _channel = WebSocketChannel.connect(Uri.parse(config.url));
    _wsSubscription = _channel.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );
    _isConnected = true;
    _startConnectivityMonitoring();
  }

  Future<void> disconnect() async {
    logger.info('WebitelSocket: Disconnecting...');
    _isConnected = false;
    await _wsSubscription.cancel();
    await _channel.sink.close();
    _pendingRequests.clear();
    _outgoingQueue.clear();
    await _connectivitySubscription.cancel();
  }

  Future<void> dispose() async {
    await _agentStatusController.close();
    await _errorController.close();
    await _ackMessageController.close();
    await _wsSubscription.cancel();
    await _channel.sink.close();
    await _connectivitySubscription.cancel();
  }

  void _onMessage(dynamic message) async {
    logger.debug('WebitelSocket: Received message: $message');

    final Map<String, dynamic> data = jsonDecode(message);
    final replySeq = data['seq_reply'];
    final event = fromString(data['event']);

    // ---- Handle replies to requests ----
    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      final completer = _pendingRequests.remove(replySeq)!;

      try {
        final typedData = Map<String, dynamic>.from(data);
        final status = typedData['status'];

        if (status == 'OK') {
          final responseData = typedData['data'];
          if (responseData is Map && responseData.isNotEmpty) {
            completer.complete(Map<String, dynamic>.from(responseData));
          } else {
            completer.complete(typedData);
          }
        } else {
          final error = SocketError.fromJson(typedData['error'] ?? {});
          _errorController.add(error);
          if (status == 'FAIL') {
            completer.complete({'error': error});
          } else {
            completer.completeError(error);
          }
        }
      } catch (e, stack) {
        _errorController.add(
          SocketError(
            code: 500,
            id: 'websocket.parse_error',
            status: 'Error',
            detail: e.toString(),
          ),
        );
        completer.completeError(e, stack);
      }
      return;
    }

    // ---- Handle pushed events ----
    switch (event) {
      case WebSocketEvent.agentStatus:
        final agentData = data['data'] ?? {};
        final status = agentData['status'];

        final AgentStatus agentStatus = switch (status) {
          'online' => AgentStatus.online,
          'offline' => AgentStatus.offline,
          'pause' => AgentStatus.pause,
          _ => AgentStatus.unknown,
        };

        _agentStatusController.add(agentStatus);
        if (agentStatus == AgentStatus.unknown) {
          logger.warn('Unknown agent status received: $status');
        }
        break;

      case WebSocketEvent.hello:
        logger.info('WebitelSocket: Received "hello": ${data['data']}');
        _ackMessageController.add(data);
        break;

      case WebSocketEvent.call:
        final callData = data['data']?['call'];
        final callEvent = callData?['event'];
        final callId = callData?['id'];

        logger.info('[WebitelSocket] Call event: $callEvent | id: $callId');

        switch (callEvent) {
          case 'ringing':
            _onCallRinging?.call(callId);
            break;
          case 'hangup':
            _onCallHangup?.call(callId);
            break;
          default:
            logger.debug('[WebitelSocket] Unhandled call event: $callEvent');
        }
        break;

      case WebSocketEvent.notification:
        await _handleNotification(data['data']?['notification']);
        break;

      case WebSocketEvent.unknown:
        final eventName = data['event'];
        logger.debug('WebitelSocket: Unhandled event: $eventName');
        break;
    }
  }

  Future<void> _handleNotification(Map<String, dynamic>? notif) async {
    if (notif == null) return;

    final action = notif['action'];
    final body = notif['body'] as Map<String, dynamic>?;

    if (action == 'screen_share' && body != null) {
      final sdp = body['sdp'] as String?;
      final parentId = body['parent_id'] as String?;
      final fromUserId = body['from_user_id'];
      final sockId = body['sock_id'];

      if (sdp != null && parentId != null) {
        logger.info(
          '[WebitelSocket] screen_share received, parent_id=$parentId',
        );

        _screenCapturer?.close('new screen_share');
        final localStream = await captureDesktopScreen();
        _screenCapturer = ScreenStreamer(
          id: parentId,
          peerSdp: sdp,
          iceServers: [],
          logger: logger,
          localStream: localStream,
          onTrack: (MediaStream stream) {
            logger.info('[WebitelSocket] Screen stream received!');
            onStreamReceived?.call(stream);
          },
          onClose: () {
            logger.info('[WebitelSocket] Screen stream closed');
          },
        );

        await _screenCapturer!.start();
        var answer = await _screenCapturer!.localDescription;
        if (answer != null) {
          final filteredSdp = filterSdp(answer.sdp ?? '');
          answer = RTCSessionDescription(filteredSdp, answer.type);

          // final sessionId = Uuid().v4();
          await request('ss_accept', {
            'id': notif['id'],
            'sdp': answer.sdp,
            'to_user_id': fromUserId,
            'sock_id': sockId,
            'session_id': parentId,
          });
        } else {
          logger.error(
            '[WebitelSocket] localDescription is null after start()',
          );
        }
      }
    }
  }

  String filterSdp(String sdp) {
    // Only filter problematic lines, keep ICE candidates
    return sdp
        .split('\n')
        .where((line) => !line.contains('0.0.0.0') && !line.contains('::1'))
        .join('\n');
  }

  void onCallEvent({
    void Function(String callId)? onRinging,
    void Function(String callId)? onHangup,
  }) {
    _onCallRinging = onRinging;
    _onCallHangup = onHangup;
  }

  void _onError(dynamic error) {
    logger.error('WebitelSocket: Socket error: $error');
    for (final completer in _pendingRequests.values) {
      completer.completeError(error);
    }
    _pendingRequests.clear();
    _outgoingQueue.clear();
    _isConnected = false;

    _errorController.add(
      SocketError(
        id: 'websocket.error',
        status: 'Socket Error',
        detail: error.toString(),
        code: 0,
      ),
    );
    _reconnect();
  }

  void _onDone() {
    logger.warn('WebitelSocket: Connection closed.');
    _isConnected = false;
    _reconnect();
  }

  void _startConnectivityMonitoring() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      if (results.contains(ConnectivityResult.none)) {
        logger.warn('WebitelSocket: No internet connectivity.');
        _isConnected = false;
      } else if (!_isConnected) {
        logger.info(
          'WebitelSocket: Internet connectivity restored. Attempting to reconnect.',
        );
        _reconnect();
      }
    });
  }

  Future<void> _reconnect() async {
    if (_isConnected) {
      logger.debug('WebitelSocket: Already connected, no need to reconnect.');
      return;
    }

    // Prevent multiple concurrent reconnection attempts
    if (_reconnecting) {
      logger.debug('WebitelSocket: Reconnection in progress.');
      return;
    }

    _reconnecting = true; // Set flag to indicate reconnection is in progress
    logger.info('WebitelSocket: Attempting to reconnect in 5 seconds...');

    try {
      await Future.delayed(const Duration(seconds: 5));
      if (!_isConnected) {
        // Double-check in case connection was established by another trigger
        await connect();
        logger.info('WebitelSocket: Reconnected successfully.');

        // --- IMPORTANT: RE-AUTHENTICATE AFTER RECONNECTION ---
        try {
          await authenticate();
          logger.info('WebitelSocket: Re-authenticated successfully.');
          // Optionally, re-fetch agent session or status if needed after auth
          // await getAgentSession();
        } catch (authError) {
          logger.error('WebitelSocket: Re-authentication failed: $authError');
          // If authentication fails, the reconnection is not truly successful.
          // Trigger another reconnect attempt.
          _isConnected = false; // Mark as disconnected so _reconnect can retry
          _reconnecting = false; // Reset flag before re-calling
          _reconnect();
          return; // Exit current _reconnect cycle
        }
      }
    } catch (e) {
      logger.error('WebitelSocket: Reconnection failed: $e');
      // If connection fails, trigger another reconnect attempt
      _isConnected = false; // Ensure disconnected state
      _reconnecting = false; // Reset flag before re-calling
      _reconnect();
      return; // Exit current _reconnect cycle
    } finally {
      // Only set _reconnecting to false if we are not immediately re-calling it due to auth failure
      if (_reconnecting) {
        _reconnecting = false;
      }
    }
  }

  // New flag to prevent multiple concurrent reconnection attempts
  bool _reconnecting = false;

  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? data,
  ]) {
    final currentSeq = _seq++;
    final completer = Completer<Map<String, dynamic>>();

    final payload = {
      'seq': currentSeq,
      'action': action,
      if (data != null) 'data': data,
    };

    _pendingRequests[currentSeq] = completer;
    _outgoingQueue.add(_QueuedRequest(payload));
    _startSendLoop();

    return completer.future;
  }

  void _startSendLoop() {
    if (_isSending) return;
    _isSending = true;

    Future.doWhile(() async {
      if (_outgoingQueue.isEmpty || !_isConnected) {
        _isSending = false;
        return false;
      }

      final req = _outgoingQueue.removeFirst();
      _channel.sink.add(jsonEncode(req.payload));

      await Future.delayed(const Duration(milliseconds: 5));
      return true;
    });
  }

  //--------------------------------
  // ------ Public API methods -----
  //--------------------------------
  Future<AuthResponse> authenticate() async {
    final response = await request(SocketActions.authenticationChallenge, {
      'token': _token,
    });

    if (response.containsKey('error')) {
      if (onAuthenticationFailed != null) {
        onAuthenticationFailed!();
      }
    }

    return AuthResponse.fromJson(response);
  }

  Future<AgentSession> getAgentSession() async {
    final response = await request(SocketActions.agentSession);
    return AgentSession.fromJson(response);
  }

  Future<UserDeviceConfig> getUserDefaultDevice() async {
    final response = await request(SocketActions.userDefaultDevice);
    return UserDeviceConfig.fromJson(response);
  }

  Future<void> setAgentStatus(
    int agentId,
    AgentStatus status, {
    String payload = '',
  }) async {
    final action = switch (status) {
      AgentStatus.online => SocketActions.agentOnline,
      AgentStatus.offline => SocketActions.agentOffline,
      AgentStatus.pause => SocketActions.agentPause,
      _ => throw Exception('Unsupported agent status'),
    };

    final data = <String, dynamic>{'agent_id': agentId};
    if (payload.isNotEmpty) data['status_payload'] = payload;

    final res = await request(action, data);
    if (res['status'] != 'OK') {
      logger.error('Failed to set agent status: ${res['status']}');
      // Optionally throw an error or handle the failure
      // throw Exception('Failed to set agent status: ${res['status']}');
    }

    _agentStatusController.add(status);
  }

  Future<void> setOnline(int agentId) =>
      setAgentStatus(agentId, AgentStatus.online);

  Future<void> setOffline(int agentId) =>
      setAgentStatus(agentId, AgentStatus.offline);

  Future<void> setPause({required int agentId, required String payload}) =>
      setAgentStatus(agentId, AgentStatus.pause, payload: payload);
}

class _QueuedRequest {
  final Map<String, dynamic> payload;

  _QueuedRequest(this.payload);
}
