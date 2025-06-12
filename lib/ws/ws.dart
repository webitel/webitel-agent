// websocket_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'model/agent.dart';
import 'model/auth.dart';
import 'model/user.dart';

class WebitelSocket {
  final WebitelSocketConfig config;

  late WebSocketChannel _channel;
  late StreamSubscription _subscription;

  int _seq = 1;

  // Maps seq number of requests to their Completers for awaiting responses
  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};

  // StreamController broadcasting the current agent status ('online', 'offline', 'pause')
  final StreamController<String> _agentStatusController =
      StreamController.broadcast();

  Stream<String> get agentStatusStream => _agentStatusController.stream;

  // Queue for pending status updates to be sent sequentially (seq -> action)
  final Map<int, String> _pendingStatusUpdates = {};

  // Flag indicating if a status request is currently being sent
  bool _isSendingStatus = false;

  WebitelSocket({required this.config});

  /// Connects to the WebSocket server and starts listening for messages
  Future<void> connect() async {
    _channel = WebSocketChannel.connect(Uri.parse(config.url));
    _subscription = _channel.stream.listen(_onMessage, onError: _onError);
  }

  /// Disconnects from the WebSocket server and cleans up state
  Future<void> disconnect() async {
    await _subscription.cancel();
    await _channel.sink.close();
    _pendingRequests.clear();
    _pendingStatusUpdates.clear();
  }

  /// Handles incoming WebSocket messages
  void _onMessage(dynamic message) {
    final data = jsonDecode(message);

    final replySeq = data['seq_reply']; // For request response
    final event = data['event']; // For pushed events

    // Handle replies to requests (completers)
    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      final completer = _pendingRequests.remove(replySeq)!;

      // Cast to Map<String, dynamic>
      final Map<String, dynamic> typedData = Map<String, dynamic>.from(data);

      if (typedData['status'] == 'OK') {
        final responseData = typedData['data'];
        if (responseData != null &&
            responseData is Map &&
            responseData.isNotEmpty) {
          completer.complete(Map<String, dynamic>.from(responseData));
        } else {
          completer.complete(typedData);
        }
      } else {
        completer.completeError(
          Exception(typedData['status'] ?? 'Unknown error'),
        );
      }
    }
  }

  /// Handles errors on WebSocket stream - completes all pending requests with error
  void _onError(error) {
    for (final completer in _pendingRequests.values) {
      completer.completeError(error);
    }
    _pendingRequests.clear();
    _pendingStatusUpdates.clear();
  }

  /// Generic method to send a request with action and optional data, returns Future with response
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? data,
  ]) {
    final currentSeq = _seq++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[currentSeq] = completer;

    final payload = {
      'seq': currentSeq,
      'action': action,
      if (data != null) 'data': data,
    };

    _channel.sink.add(jsonEncode(payload));
    return completer.future;
  }

  /// Sends authentication request
  Future<AuthResponse> authenticate() async {
    final response = await request('authentication_challenge', {
      'token': config.token,
    });

    return AuthResponse.fromJson(response);
  }

  Future<AgentSession> getAgentSession() async {
    final response = await request('cc_agent_session');
    return AgentSession.fromJson(response);
  }

  Future<UserDeviceConfig> getUserDefaultDevice() async {
    final response = await request('user_default_device');
    return UserDeviceConfig.fromJson(response);
  }

  Future<void> _sendStatus(
    int agentId,
    String action, [
    String statusPayload = '',
  ]) async {
    // Enqueue the action to send, including optional payload
    final seq = _seq++;
    _pendingStatusUpdates[seq] = action;

    if (_isSendingStatus) {
      // Already sending, just enqueue and return
      return;
    }

    _isSendingStatus = true;

    try {
      while (_pendingStatusUpdates.isNotEmpty) {
        final nextEntry = _pendingStatusUpdates.entries.first;
        _pendingStatusUpdates.remove(nextEntry.key);

        // Prepare request data
        final data = <String, dynamic>{'agent_id': agentId};
        if (statusPayload.isNotEmpty) {
          data['status_payload'] = statusPayload;
        }

        // Send the request
        final response = await request(nextEntry.value, data);

        if (response['status'] != 'OK') {
          throw Exception(
            'Failed to set agent ${nextEntry.value}: ${response['status']}',
          );
        }

        // **Emit local status update to stream here**
        // Map the action to a status string for the stream
        String statusForStream;
        switch (nextEntry.value) {
          case 'cc_agent_online':
            statusForStream = 'online';
            break;
          case 'cc_agent_offline':
            statusForStream = 'offline';
            break;
          case 'cc_agent_pause':
            statusForStream = 'pause';
            break;
          default:
            statusForStream = 'unknown';
        }
        _agentStatusController.add(statusForStream);

        // Clear the statusPayload after first use if needed
        statusPayload = '';
      }
    } finally {
      _isSendingStatus = false;
    }
  }

  /// Sets agent online status
  Future<void> setOnline(int agentId) =>
      _sendStatus(agentId, 'cc_agent_online');

  /// Sets agent offline status
  Future<void> setOffline(int agentId) =>
      _sendStatus(agentId, 'cc_agent_offline');

  /// Sets agent pause status with optional status payload
  Future<void> setPause({
    required int agentId,
    required String statusPayload,
  }) => _sendStatus(agentId, 'cc_agent_pause', statusPayload);
}
