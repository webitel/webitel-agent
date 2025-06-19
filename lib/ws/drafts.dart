// import 'dart:async';
// import 'dart:collection';
// import 'dart:convert';
//
// import 'package:connectivity_plus/connectivity_plus.dart';
// import 'package:web_socket_channel/web_socket_channel.dart';
// import 'package:webitel_agent_flutter/logger.dart';
// import 'package:webitel_agent_flutter/ws/config.dart';
// import 'package:webitel_agent_flutter/ws/constants.dart';
// import 'package:webitel_agent_flutter/ws/model/agent.dart';
// import 'package:webitel_agent_flutter/ws/model/auth.dart';
// import 'package:webitel_agent_flutter/ws/model/user.dart';
//
// import 'model/ws_error.dart';
//
// enum AgentStatus { online, offline, pause, unknown }
//
// class WebitelSocket {
//   final WebitelSocketConfig config;
//
//   late WebSocketChannel _channel;
//   late StreamSubscription _wsSubscription;
//   late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
//
//   final _agentStatusController = StreamController<AgentStatus>.broadcast();
//   final _errorController = StreamController<SocketError>.broadcast();
//   final _ackMessageController =
//       StreamController<
//         Map<String, dynamic>
//       >.broadcast(); // New: for "ack" message
//
//   final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};
//   final _outgoingQueue = Queue<_QueuedRequest>();
//
//   final logger = LoggerService();
//
//   int _seq = 1;
//   bool _isConnected = false;
//   bool _isSending = false;
//
//   WebitelSocket({required this.config});
//
//   /// Public Streams
//   Stream<AgentStatus> get agentStatusStream => _agentStatusController.stream;
//
//   Stream<SocketError> get errorStream => _errorController.stream;
//
//   /// New: Stream for "hello" acknowledgement messages
//   Stream<Map<String, dynamic>> get ackMessageStream =>
//       _ackMessageController.stream;
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
//     _startConnectivityMonitoring(); // Start monitoring connectivity
//   }
//
//   Future<void> disconnect() async {
//     logger.info('WebitelSocket: Disconnecting...');
//     _isConnected = false;
//     await _wsSubscription.cancel();
//     await _channel.sink.close();
//     _pendingRequests.clear();
//     _outgoingQueue.clear();
//     await _connectivitySubscription
//         .cancel(); // Cancel connectivity subscription
//   }
//
//   Future<void> dispose() async {
//     await _agentStatusController.close();
//     await _errorController.close();
//     await _ackMessageController.close(); // Close the new stream controller
//     await _wsSubscription.cancel();
//     await _channel.sink.close();
//     await _connectivitySubscription.cancel();
//   }
//
//   void _onMessage(dynamic message) {
//     logger.debug('WebitelSocket: Received message: $message');
//
//     final Map<String, dynamic> data = jsonDecode(message);
//     final replySeq = data['seq_reply'];
//     final event = data['event'];
//
//     // ---- Handle replies to requests (using seq_reply) ----
//     if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
//       final completer = _pendingRequests.remove(replySeq)!;
//
//       try {
//         final typedData = Map<String, dynamic>.from(data);
//
//         if (typedData['status'] == 'OK') {
//           final responseData = typedData['data'];
//           if (responseData is Map && responseData.isNotEmpty) {
//             completer.complete(Map<String, dynamic>.from(responseData));
//           } else {
//             completer.complete(typedData);
//           }
//         } else if (typedData['status'] == 'FAIL') {
//           final error = SocketError.fromJson(typedData['error'] ?? {});
//           _errorController.add(error);
//
//           // Instead of completing with error (which throws when awaited),
//           // complete with a wrapper result indicating failure:
//           completer.complete({'error': error});
//           return;
//         } else {
//           final error = SocketError.fromJson(typedData['error'] ?? {});
//           _errorController.add(error);
//           completer.completeError(error);
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
//
//       return;
//     }
//
//     // ---- Handle pushed events (no seq_reply), like "agent_status" or "hello" ----
//     if (event != null) {
//       switch (event) {
//         case 'agent_status':
//           final agentData = data['data'] ?? {};
//           final status = agentData['status'];
//
//           if (status == 'online') {
//             _agentStatusController.add(AgentStatus.online);
//           } else if (status == 'offline') {
//             _agentStatusController.add(AgentStatus.offline);
//           } else if (status == 'pause') {
//             _agentStatusController.add(AgentStatus.pause);
//           } else {
//             logger.warn('Unknown agent status received: $status');
//             _agentStatusController.add(AgentStatus.unknown);
//           }
//           break;
//         case 'hello':
//           // Handle the "hello" acknowledgement message
//           logger.info(
//             'WebitelSocket: Received "hello" acknowledgement: ${data['data']}',
//           );
//           _ackMessageController.add(
//             data,
//           ); // Add the full "hello" message to the stream
//           break;
//         default:
//           logger.debug('Unhandled event: $event');
//       }
//     }
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
//     _reconnect(); // Attempt to reconnect on error
//   }
//
//   void _onDone() {
//     logger.warn('WebitelSocket: Connection closed.');
//     _isConnected = false;
//     _reconnect(); // Attempt to reconnect on connection closure
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
//   void _reconnect() {
//     if (_isConnected) {
//       logger.debug('WebitelSocket: Already connected, no need to reconnect.');
//       return;
//     }
//     logger.info('WebitelSocket: Attempting to reconnect in 5 seconds...');
//     Future.delayed(const Duration(seconds: 5), () async {
//       if (!_isConnected) {
//         try {
//           await connect();
//           logger.info('WebitelSocket: Reconnected successfully.');
//           // You might want to re-authenticate or re-establish agent status here
//           // For example:
//           // await authenticate();
//           // await getAgentSession();
//         } catch (e) {
//           logger.error('WebitelSocket: Reconnection failed: $e');
//           _reconnect(); // Keep trying to reconnect
//         }
//       }
//     });
//   }
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
//       'token': config.token,
//     });
//     return AuthResponse.fromJson(response);
//   }
//
//   Future<AgentSession> getAgentSession() async {
//     final response = await request(SocketActions.agentSession);
//     return AgentSession.fromJson(response);
//   }
//
//   Future<UserDeviceConfig> getUserDefaultDevice() async {
//     final response = await request(SocketActions.userDefaultDevice);
//     return UserDeviceConfig.fromJson(response);
//   }
//
//   Future<void> setAgentStatus(
//     int agentId,
//     AgentStatus status, {
//     String payload = '',
//   }) async {
//     final action = switch (status) {
//       AgentStatus.online => SocketActions.agentOnline,
//       AgentStatus.offline => SocketActions.agentOffline,
//       AgentStatus.pause => SocketActions.agentPause,
//       _ => throw Exception('Unsupported agent status'),
//     };
//
//     final data = <String, dynamic>{'agent_id': agentId};
//     if (payload.isNotEmpty) data['status_payload'] = payload;
//
//     final res = await request(action, data);
//     if (res['status'] != 'OK') {
//       logger.error('Failed to set agent status: ${res['status']}');
//     }
//
//     _agentStatusController.add(status);
//   }
//
//   Future<void> setOnline(int agentId) =>
//       setAgentStatus(agentId, AgentStatus.online);
//
//   Future<void> setOffline(int agentId) =>
//       setAgentStatus(agentId, AgentStatus.offline);
//
//   Future<void> setPause({required int agentId, required String payload}) =>
//       setAgentStatus(agentId, AgentStatus.pause, payload: payload);
// }
//
// class _QueuedRequest {
//   final Map<String, dynamic> payload;
//
//   _QueuedRequest(this.payload);
// }

// import 'dart:async';
// import 'dart:collection';
// import 'dart:convert';
//
// import 'package:connectivity_plus/connectivity_plus.dart';
// import 'package:web_socket_channel/web_socket_channel.dart';
// import 'package:webitel_agent_flutter/logger.dart';
// import 'package:webitel_agent_flutter/ws/config.dart';
// import 'package:webitel_agent_flutter/ws/constants.dart';
// import 'package:webitel_agent_flutter/ws/model/agent.dart';
// import 'package:webitel_agent_flutter/ws/model/auth.dart';
// import 'package:webitel_agent_flutter/ws/model/user.dart';
//
// import 'model/ws_error.dart';
//
// enum AgentStatus { online, offline, pause, unknown }
//
// class WebitelSocket {
//   final WebitelSocketConfig config;
//
//   late WebSocketChannel _channel;
//   late StreamSubscription _wsSubscription;
//   late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
//
//   final _agentStatusController = StreamController<AgentStatus>.broadcast();
//   final _errorController = StreamController<SocketError>.broadcast();
//   final _ackMessageController =
//       StreamController<
//         Map<String, dynamic>
//       >.broadcast(); // New: for "ack" message
//
//   final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};
//   final _outgoingQueue = Queue<_QueuedRequest>();
//
//   final logger = LoggerService();
//
//   int _seq = 1;
//   bool _isConnected = false;
//   bool _isSending = false;
//
//   WebitelSocket({required this.config});
//
//   /// Public Streams
//   Stream<AgentStatus> get agentStatusStream => _agentStatusController.stream;
//
//   Stream<SocketError> get errorStream => _errorController.stream;
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
//   }
//
//   Future<void> disconnect() async {
//     logger.info('WebitelSocket: Disconnecting...');
//     _isConnected = false;
//     await _wsSubscription.cancel();
//     await _channel.sink.close();
//     _pendingRequests.clear();
//     _outgoingQueue.clear();
//   }
//
//   Future<void> dispose() async {
//     await _agentStatusController.close();
//     await _errorController.close();
//     await _wsSubscription.cancel();
//     await _channel.sink.close();
//     await _connectivitySubscription.cancel();
//   }
//
//   void _onMessage(dynamic message) {
//     logger.debug('WebitelSocket: Received message: $message');
//
//     final Map<String, dynamic> data = jsonDecode(message);
//     final replySeq = data['seq_reply'];
//     final event = data['event'];
//
//     // ---- Handle replies to requests (using seq_reply) ----
//     if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
//       final completer = _pendingRequests.remove(replySeq)!;
//
//       try {
//         final typedData = Map<String, dynamic>.from(data);
//
//         if (typedData['status'] == 'OK') {
//           final responseData = typedData['data'];
//           if (responseData is Map && responseData.isNotEmpty) {
//             completer.complete(Map<String, dynamic>.from(responseData));
//           } else {
//             completer.complete(typedData);
//           }
//         } else if (typedData['status'] == 'FAIL') {
//           final error = SocketError.fromJson(typedData['error'] ?? {});
//           _errorController.add(error);
//
//           // Instead of completing with error (which throws when awaited),
//           // complete with a wrapper result indicating failure:
//           completer.complete({'error': error});
//           return;
//         } else {
//           final error = SocketError.fromJson(typedData['error'] ?? {});
//           _errorController.add(error);
//           completer.completeError(error);
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
//
//       return;
//     }
//
//     // ---- Handle pushed events (no seq_reply), like "agent_status" or "ack" ----
//     if (event != null) {
//       switch (event) {
//         case 'agent_status':
//           final agentData = data['data'] ?? {};
//           final status = agentData['status'];
//
//           if (status == 'online') {
//             _agentStatusController.add(AgentStatus.online);
//           } else if (status == 'offline') {
//             _agentStatusController.add(AgentStatus.offline);
//           } else if (status == 'pause') {
//             _agentStatusController.add(AgentStatus.pause);
//           } else {
//             logger.warn('Unknown agent status received: $status');
//             _agentStatusController.add(AgentStatus.unknown);
//           }
//           break;
//
//         default:
//           logger.debug('Unhandled event: $event');
//       }
//     }
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
//   }
//
//   void _onDone() {
//     logger.warn('WebitelSocket: Connection closed.');
//     _isConnected = false;
//   }
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
//       'token': config.token,
//     });
//     return AuthResponse.fromJson(response);
//   }
//
//   Future<AgentSession> getAgentSession() async {
//     final response = await request(SocketActions.agentSession);
//     return AgentSession.fromJson(response);
//   }
//
//   Future<UserDeviceConfig> getUserDefaultDevice() async {
//     final response = await request(SocketActions.userDefaultDevice);
//     return UserDeviceConfig.fromJson(response);
//   }
//
//   Future<void> setAgentStatus(
//     int agentId,
//     AgentStatus status, {
//     String payload = '',
//   }) async {
//     final action = switch (status) {
//       AgentStatus.online => SocketActions.agentOnline,
//       AgentStatus.offline => SocketActions.agentOffline,
//       AgentStatus.pause => SocketActions.agentPause,
//       _ => throw Exception('Unsupported agent status'),
//     };
//
//     final data = <String, dynamic>{'agent_id': agentId};
//     if (payload.isNotEmpty) data['status_payload'] = payload;
//
//     final res = await request(action, data);
//     if (res['status'] != 'OK') {
//       logger.error('Failed to set agent status: ${res['status']}');
//     }
//
//     _agentStatusController.add(status);
//   }
//
//   Future<void> setOnline(int agentId) =>
//       setAgentStatus(agentId, AgentStatus.online);
//
//   Future<void> setOffline(int agentId) =>
//       setAgentStatus(agentId, AgentStatus.offline);
//
//   Future<void> setPause({required int agentId, required String payload}) =>
//       setAgentStatus(agentId, AgentStatus.pause, payload: payload);
// }
//
// class _QueuedRequest {
//   final Map<String, dynamic> payload;
//
//   _QueuedRequest(this.payload);
// }
