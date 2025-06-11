import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'model/agent.dart';
import 'model/auth.dart';
import 'model/user.dart';

const _websocketUrl = 'wss://dev.webitel.com/ws/websocket';

class WebitelSocket {
  final String token;
  late WebSocketChannel _channel;
  late StreamSubscription _subscription;
  int _seq = 1;

  final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};

  WebitelSocket(this.token);

  Future<void> connect() async {
    _channel = WebSocketChannel.connect(Uri.parse(_websocketUrl));
    _subscription = _channel.stream.listen(_onMessage, onError: _onError);
  }

  Future<void> disconnect() async {
    await _subscription.cancel();
    await _channel.sink.close();
    _pendingRequests.clear();
  }

  void _onMessage(dynamic message) {
    final data = jsonDecode(message);
    final int? replySeq = data['seq_reply'];

    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      final completer = _pendingRequests.remove(replySeq)!;

      if (data['status'] == 'OK') {
        final payload = data['data'];
        if (payload is Map<String, dynamic>) {
          completer.complete(payload);
        } else {
          completer.complete(<String, dynamic>{});
        }
      } else {
        completer.completeError(Exception(data['status'] ?? 'Unknown error'));
      }
    }
  }

  void _onError(error) {
    for (final completer in _pendingRequests.values) {
      completer.completeError(error);
    }
    _pendingRequests.clear();
  }

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

  Future<AuthResponse> authenticate() async {
    final response = await request('authentication_challenge', {
      'token': token,
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
}
