// socket/webitel_socket.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webitel_agent_flutter/ws/ws_config.dart';

import '../logger.dart';
import '../screenshot.dart';
import '../tray.dart';
import '../webrtc/session/screen_streamer.dart';
import '../ws/constants.dart';
import '../ws/model/agent.dart';
import '../ws/model/auth.dart';
import '../ws/model/ws_error.dart';
import 'notification_action.dart';
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

  int _seq = 1;
  bool _isConnected = false;
  bool _isSending = false;
  bool _reconnecting = false;

  void Function(String callId)? _onCallRinging;
  void Function(String callId)? _onCallHangup;
  void Function(Map<String, dynamic> body)? onScreenRecordStart;
  void Function(Map<String, dynamic> body)? onScreenRecordStop;
  void Function()? onAuthenticationFailed;

  ScreenStreamer? _screenCapturer;
  late final ScreenshotSenderService screenshotService;

  WebitelSocket({required this.config}) {
    _token = config.token;
    screenshotService = ScreenshotSenderService(
      uploadUrl: config.mediaUploadUrl,
    );
  }

  // Public Streams
  Stream<AgentStatus> get agentStatusStream => _agentStatusController.stream;

  Stream<SocketError> get errorStream => _errorController.stream;

  Stream<Map<String, dynamic>> get ackMessageStream =>
      _ackMessageController.stream;

  void updateToken(String newToken) {
    _token = newToken;
    logger.info('WebitelSocket: Token updated.');
  }

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

    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      _handleReply(data, replySeq);
      return;
    }

    switch (event) {
      case WebSocketEvent.agentStatus:
        _handleAgentStatus(data);
        break;
      case WebSocketEvent.hello:
        _ackMessageController.add(data);
        break;
      case WebSocketEvent.call:
        _handleCallEvent(data);
        break;
      case WebSocketEvent.notification:
        await _handleNotification(data);
        break;
      case WebSocketEvent.unknown:
        logger.debug('WebitelSocket: Unhandled event: ${data['event']}');
        break;
    }
  }

  void _handleReply(Map<String, dynamic> data, int replySeq) {
    final completer = _pendingRequests.remove(replySeq)!;

    try {
      final typedData = Map<String, dynamic>.from(data);
      final status = typedData['status'];

      if (status == 'OK') {
        final responseData = typedData['data'];

        if (responseData is Map && responseData.containsKey('status')) {
          final agentStatus = _parseAgentStatus(responseData['status']);
          _agentStatusController.add(agentStatus);
          TrayService.instance.updateStatus(responseData['status']);
        }

        completer.complete(
          responseData is Map && responseData.isNotEmpty
              ? Map<String, dynamic>.from(responseData)
              : typedData,
        );
      } else {
        final error = SocketError.fromJson(typedData['error'] ?? {});
        _errorController.add(error);
        status == 'FAIL'
            ? completer.complete({'error': error})
            : completer.completeError(error);
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
  }

  AgentStatus _parseAgentStatus(String? status) => switch (status) {
    'online' => AgentStatus.online,
    'offline' => AgentStatus.offline,
    'pause' => AgentStatus.pause,
    _ => AgentStatus.unknown,
  };

  void _handleAgentStatus(Map<String, dynamic> data) {
    final status = data['data']?['status'];
    final agentStatus = _parseAgentStatus(status);
    _agentStatusController.add(agentStatus);
    if (agentStatus == AgentStatus.unknown) {
      logger.warn('Unknown agent status received: $status');
    }
  }

  void _handleCallEvent(Map<String, dynamic> data) {
    final call = data['data']?['call'];
    final callEvent = call?['event'];
    final callId = call?['id'];

    switch (callEvent) {
      case 'ringing':
        _onCallRinging?.call(callId);
        break;
      case 'hangup':
        _onCallHangup?.call(callId);
        break;
    }
  }

  Future<void> _handleNotification(Map<String, dynamic> data) async {
    final notif = data['data']?['notification'];
    final actionStr = notif?['action'] as String?;
    final action = NotificationAction.fromString(actionStr);
    final body = Map<String, dynamic>.from(notif?['body'] ?? {});

    switch (action) {
      case NotificationAction.screenShare:
        _screenCapturer?.close('new screen_share');
        _screenCapturer = await ScreenStreamer.fromNotification(
          notif: notif,
          logger: logger,
          onClose: () => logger.info('[WebitelSocket] Screen stream closed'),
          onAccept: request,
        );
        break;

      case NotificationAction.screenshot:
        await screenshotService.screenshot();
        break;

      case NotificationAction.screenRecordStart:
        onScreenRecordStart?.call(body);
        break;

      case NotificationAction.screenRecordStop:
        onScreenRecordStop?.call(body);
        break;

      case NotificationAction.unknown:
        logger.debug('[WebitelSocket] Unknown notification action: $actionStr');
        break;
    }
  }

  void onCallEvent({
    void Function(String callId)? onRinging,
    void Function(String callId)? onHangup,
  }) {
    _onCallRinging = onRinging;
    _onCallHangup = onHangup;
  }

  void onScreenRecordEvent({
    void Function(Map<String, dynamic> body)? onStart,
    void Function(Map<String, dynamic> body)? onStop,
  }) {
    onScreenRecordStart = onStart;
    onScreenRecordStop = onStop;
  }

  void _onError(dynamic error) {
    logger.error('WebitelSocket: Socket error: $error');
    _pendingRequests.values.forEach((c) => c.completeError(error));
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
      results,
    ) {
      if (results.contains(ConnectivityResult.none)) {
        _isConnected = false;
      } else if (!_isConnected) {
        _reconnect();
      }
    });
  }

  Future<void> _reconnect() async {
    if (_isConnected || _reconnecting) return;
    _reconnecting = true;

    await Future.delayed(const Duration(seconds: 5));
    if (!_isConnected) {
      try {
        await connect();
        await authenticate();
      } catch (e) {
        _isConnected = false;
        _reconnecting = false;
        _reconnect();
        return;
      }
    }
    _reconnecting = false;
  }

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

  Future<AuthResponse> authenticate() async {
    final response = await request(SocketActions.authenticationChallenge, {
      'token': _token,
    });

    if (response.containsKey('error')) {
      onAuthenticationFailed?.call();
    }

    return AuthResponse.fromJson(response);
  }

  Future<AgentSession> getAgentSession() async {
    final response = await request(SocketActions.agentSession);
    return AgentSession.fromJson(response);
  }
}

class _QueuedRequest {
  final Map<String, dynamic> payload;

  _QueuedRequest(this.payload);
}

// import 'dart:async';
// import 'dart:collection';
// import 'dart:convert';
//
// import 'package:connectivity_plus/connectivity_plus.dart';
// import 'package:web_socket_channel/web_socket_channel.dart';
// import 'package:webitel_agent_flutter/logger.dart';
// import 'package:webitel_agent_flutter/screenshot.dart';
// import 'package:webitel_agent_flutter/tray.dart';
// import 'package:webitel_agent_flutter/webrtc/session/screen_streamer.dart';
// import 'package:webitel_agent_flutter/ws/constants.dart';
// import 'package:webitel_agent_flutter/ws/model/agent.dart';
// import 'package:webitel_agent_flutter/ws/model/auth.dart';
// import 'package:webitel_agent_flutter/ws/ws_config.dart';
//
// import 'model/ws_error.dart';
// import 'ws_events.dart';
//
// enum AgentStatus { online, offline, pause, unknown }
//
// class WebitelSocket {
//   final WebitelSocketConfig config;
//
//   late String _token;
//
//   late WebSocketChannel _channel;
//   late StreamSubscription _wsSubscription;
//   late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
//
//   final _agentStatusController = StreamController<AgentStatus>.broadcast();
//   final _errorController = StreamController<SocketError>.broadcast();
//   final _ackMessageController =
//       StreamController<Map<String, dynamic>>.broadcast();
//
//   final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};
//   final _outgoingQueue = Queue<_QueuedRequest>();
//
//   int _seq = 1;
//   bool _isConnected = false;
//   bool _isSending = false;
//
//   void Function(String callId)? _onCallRinging;
//   void Function(String callId)? _onCallHangup;
//
//   void Function(Map<String, dynamic> body)? onScreenRecordStart;
//   void Function(Map<String, dynamic> body)? onScreenRecordStop;
//   void Function()? onAuthenticationFailed;
//
//   ScreenStreamer? _screenCapturer;
//
//   late final ScreenshotSenderService screenshotService;
//
//   WebitelSocket({required this.config}) {
//     _token = config.token;
//     screenshotService = ScreenshotSenderService(
//       uploadUrl: config.mediaUploadUrl,
//     );
//   }
//
//   /// Public Streams
//   Stream<AgentStatus> get agentStatusStream => _agentStatusController.stream;
//
//   Stream<SocketError> get errorStream => _errorController.stream;
//
//   /// Stream for "hello" acknowledgement messages
//   Stream<Map<String, dynamic>> get ackMessageStream =>
//       _ackMessageController.stream;
//
//   void updateToken(String newToken) {
//     _token = newToken;
//     logger.info('WebitelSocket: Token updated.');
//   }
//
//   /// Connect and listen
//   Future<void> connect() async {
//     logger.info('WebitelSocket: Connecting to ${config.url}');
//     _channel = WebSocketChannel.connect(Uri.parse(config.url));
//     _wsSubscription = _channel.stream.listen(
//       _onMessage,
//       onError: _onError,
//       onDone: _onDone,
//     );
//     _isConnected = true;
//     _startConnectivityMonitoring();
//   }
//
//   Future<void> disconnect() async {
//     logger.info('WebitelSocket: Disconnecting...');
//     _isConnected = false;
//     await _wsSubscription.cancel();
//     await _channel.sink.close();
//     _pendingRequests.clear();
//     _outgoingQueue.clear();
//     await _connectivitySubscription.cancel();
//   }
//
//   Future<void> dispose() async {
//     await _agentStatusController.close();
//     await _errorController.close();
//     await _ackMessageController.close();
//     await _wsSubscription.cancel();
//     await _channel.sink.close();
//     await _connectivitySubscription.cancel();
//   }
//
//   void _onMessage(dynamic message) async {
//     logger.debug('WebitelSocket: Received message: $message');
//
//     final Map<String, dynamic> data = jsonDecode(message);
//     final replySeq = data['seq_reply'];
//     final event = fromString(data['event']);
//
//     // ---- Handle replies to requests ----
//     if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
//       final completer = _pendingRequests.remove(replySeq)!;
//
//       try {
//         final typedData = Map<String, dynamic>.from(data);
//         final status = typedData['status'];
//
//         if (status == 'OK') {
//           final responseData = typedData['data'];
//           if (responseData is Map && responseData.containsKey('status')) {
//             final rawStatus = responseData['status'] as String?;
//
//             if (rawStatus != null) {
//               final AgentStatus agentStatus = switch (rawStatus) {
//                 'online' => AgentStatus.online,
//                 'offline' => AgentStatus.offline,
//                 'pause' => AgentStatus.pause,
//                 _ => AgentStatus.unknown,
//               };
//
//               _agentStatusController.add(agentStatus);
//               TrayService.instance.updateStatus(rawStatus);
//
//               if (agentStatus == AgentStatus.unknown) {
//                 logger.warn(
//                   'Unknown agent status received (reply): $rawStatus',
//                 );
//               }
//             }
//           }
//
//           if (responseData is Map && responseData.isNotEmpty) {
//             completer.complete(Map<String, dynamic>.from(responseData));
//           } else {
//             completer.complete(typedData);
//           }
//         } else {
//           final error = SocketError.fromJson(typedData['error'] ?? {});
//           _errorController.add(error);
//           if (status == 'FAIL') {
//             completer.complete({'error': error});
//           } else {
//             completer.completeError(error);
//           }
//         }
//       } catch (e, stack) {
//         _errorController.add(
//           SocketError(
//             code: 500,
//             id: 'websocket.parse_error',
//             status: 'Error',
//             detail: e.toString(),
//           ),
//         );
//         completer.completeError(e, stack);
//       }
//       return;
//     }
//
//     // ---- Handle pushed events ----
//     switch (event) {
//       case WebSocketEvent.agentStatus:
//         final agentData = data['data'] ?? {};
//         final status = agentData['status'];
//
//         final AgentStatus agentStatus = switch (status) {
//           'online' => AgentStatus.online,
//           'offline' => AgentStatus.offline,
//           'pause' => AgentStatus.pause,
//           _ => AgentStatus.unknown,
//         };
//
//         _agentStatusController.add(agentStatus);
//         if (agentStatus == AgentStatus.unknown) {
//           logger.warn('Unknown agent status received: $status');
//         }
//         break;
//
//       case WebSocketEvent.hello:
//         logger.info('WebitelSocket: Received "hello": ${data['data']}');
//         _ackMessageController.add(data);
//         break;
//
//       case WebSocketEvent.call:
//         final callData = data['data']?['call'];
//         final callEvent = callData?['event'];
//         final callId = callData?['id'];
//
//         logger.info('[WebitelSocket] Call event: $callEvent | id: $callId');
//
//         switch (callEvent) {
//           case 'ringing':
//             _onCallRinging?.call(callId);
//             break;
//           case 'hangup':
//             _onCallHangup?.call(callId);
//             break;
//           default:
//             logger.debug('[WebitelSocket] Unhandled call event: $callEvent');
//         }
//         break;
//
//       case WebSocketEvent.notification:
//         final notif = data['data']?['notification'];
//         final action = notif?['action'];
//         final body = Map<String, dynamic>.from(notif?['body'] ?? {});
//
//         switch (action) {
//           case 'screen_share':
//             _screenCapturer?.close('new screen_share');
//
//             _screenCapturer = await ScreenStreamer.fromNotification(
//               notif: notif,
//               logger: logger,
//               onClose:
//                   () => logger.info('[WebitelSocket] Screen stream closed'),
//               onAccept: request,
//             );
//             break;
//
//           case 'screenshot':
//             logger.info('[WebitelSocket] Screenshot action received');
//             await screenshotService.screenshot();
//             break;
//
//           case 'ss_record_start':
//             logger.info('[WebitelSocket] Screen recording START received');
//             onScreenRecordStart?.call(body);
//             break;
//
//           case 'ss_record_stop':
//             logger.info('[WebitelSocket] Screen recording STOP received');
//             onScreenRecordStop?.call(body);
//             break;
//
//           default:
//             logger.debug(
//               '[WebitelSocket] Unknown notification action: $action',
//             );
//         }
//         break;
//
//       case WebSocketEvent.unknown:
//         final eventName = data['event'];
//         logger.debug('WebitelSocket: Unhandled event: $eventName');
//         break;
//     }
//   }
//
//   void onCallEvent({
//     void Function(String callId)? onRinging,
//     void Function(String callId)? onHangup,
//   }) {
//     _onCallRinging = onRinging;
//     _onCallHangup = onHangup;
//   }
//
//   void onScreenRecordEvent({
//     void Function(Map<String, dynamic> body)? onStart,
//     void Function(Map<String, dynamic> body)? onStop,
//   }) {
//     onScreenRecordStart = onStart;
//     onScreenRecordStop = onStop;
//   }
//
//   void _onError(dynamic error) {
//     logger.error('WebitelSocket: Socket error: $error');
//     for (final completer in _pendingRequests.values) {
//       completer.completeError(error);
//     }
//     _pendingRequests.clear();
//     _outgoingQueue.clear();
//     _isConnected = false;
//
//     _errorController.add(
//       SocketError(
//         id: 'websocket.error',
//         status: 'Socket Error',
//         detail: error.toString(),
//         code: 0,
//       ),
//     );
//     _reconnect();
//   }
//
//   void _onDone() {
//     logger.warn('WebitelSocket: Connection closed.');
//     _isConnected = false;
//     _reconnect();
//   }
//
//   void _startConnectivityMonitoring() {
//     _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
//       List<ConnectivityResult> results,
//     ) {
//       if (results.contains(ConnectivityResult.none)) {
//         logger.warn('WebitelSocket: No internet connectivity.');
//         _isConnected = false;
//       } else if (!_isConnected) {
//         logger.info(
//           'WebitelSocket: Internet connectivity restored. Attempting to reconnect.',
//         );
//         _reconnect();
//       }
//     });
//   }
//
//   Future<void> _reconnect() async {
//     if (_isConnected) {
//       logger.debug('WebitelSocket: Already connected, no need to reconnect.');
//       return;
//     }
//
//     // Prevent multiple concurrent reconnection attempts
//     if (_reconnecting) {
//       logger.debug('WebitelSocket: Reconnection in progress.');
//       return;
//     }
//
//     _reconnecting = true; // Set flag to indicate reconnection is in progress
//     logger.info('WebitelSocket: Attempting to reconnect in 5 seconds...');
//
//     try {
//       await Future.delayed(const Duration(seconds: 5));
//       if (!_isConnected) {
//         // Double-check in case connection was established by another trigger
//         await connect();
//         logger.info('WebitelSocket: Reconnected successfully.');
//
//         // --- IMPORTANT: RE-AUTHENTICATE AFTER RECONNECTION ---
//         try {
//           await authenticate();
//           logger.info('WebitelSocket: Re-authenticated successfully.');
//           // Optionally, re-fetch agent session or status if needed after auth
//           // await getAgentSession();
//         } catch (authError) {
//           logger.error('WebitelSocket: Re-authentication failed: $authError');
//           // If authentication fails, the reconnection is not truly successful.
//           // Trigger another reconnect attempt.
//           _isConnected = false; // Mark as disconnected so _reconnect can retry
//           _reconnecting = false; // Reset flag before re-calling
//           _reconnect();
//           return; // Exit current _reconnect cycle
//         }
//       }
//     } catch (e) {
//       logger.error('WebitelSocket: Reconnection failed: $e');
//       // If connection fails, trigger another reconnect attempt
//       _isConnected = false; // Ensure disconnected state
//       _reconnecting = false; // Reset flag before re-calling
//       _reconnect();
//       return; // Exit current _reconnect cycle
//     } finally {
//       // Only set _reconnecting to false if we are not immediately re-calling it due to auth failure
//       if (_reconnecting) {
//         _reconnecting = false;
//       }
//     }
//   }
//
//   // New flag to prevent multiple concurrent reconnection attempts
//   bool _reconnecting = false;
//
//   Future<Map<String, dynamic>> request(
//     String action, [
//     Map<String, dynamic>? data,
//   ]) {
//     final currentSeq = _seq++;
//     final completer = Completer<Map<String, dynamic>>();
//
//     final payload = {
//       'seq': currentSeq,
//       'action': action,
//       if (data != null) 'data': data,
//     };
//
//     _pendingRequests[currentSeq] = completer;
//     _outgoingQueue.add(_QueuedRequest(payload));
//     _startSendLoop();
//
//     return completer.future;
//   }
//
//   void _startSendLoop() {
//     if (_isSending) return;
//     _isSending = true;
//
//     Future.doWhile(() async {
//       if (_outgoingQueue.isEmpty || !_isConnected) {
//         _isSending = false;
//         return false;
//       }
//
//       final req = _outgoingQueue.removeFirst();
//       _channel.sink.add(jsonEncode(req.payload));
//
//       await Future.delayed(const Duration(milliseconds: 5));
//       return true;
//     });
//   }
//
//   //--------------------------------
//   // ------ Public API methods -----
//   //--------------------------------
//   Future<AuthResponse> authenticate() async {
//     final response = await request(SocketActions.authenticationChallenge, {
//       'token': _token,
//     });
//
//     if (response.containsKey('error')) {
//       if (onAuthenticationFailed != null) {
//         onAuthenticationFailed!();
//       }
//     }
//
//     return AuthResponse.fromJson(response);
//   }
//
//   Future<AgentSession> getAgentSession() async {
//     final response = await request(SocketActions.agentSession);
//     return AgentSession.fromJson(response);
//   }
// }
//
// class _QueuedRequest {
//   final Map<String, dynamic> payload;
//
//   _QueuedRequest(this.payload);
// }
