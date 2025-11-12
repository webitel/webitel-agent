// socket/webitel_socket.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/service/streaming/webrtc_streamer.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:webitel_desk_track/ws/model/agent_status.dart';
import 'package:webitel_desk_track/ws/model/notification_action.dart';
import 'package:webitel_desk_track/ws/model/ws_action.dart';
import 'package:webitel_desk_track/ws/model/ws_event.dart';
import 'package:webitel_desk_track/ws/ws_config.dart';

import '../core/logger.dart';
import '../service/screenshot/screenshot_sender.dart';
import '../service/system/tray.dart';
import '../model/agent.dart';
import '../model/auth.dart';
import 'ws_error.dart';

class WebitelSocket {
  static final WebitelSocket _instance = WebitelSocket._internal();
  static WebitelSocket get instance => _instance;

  WebitelSocketConfig? config;
  late String _token;

  WebitelSocket._internal();

  bool _screenRecordingActive = false;

  Timer? _stateCheckTimer;

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

  final List<Map<String, dynamic>> activeCalls = [];
  final List<Map<String, dynamic>> _postProcessing = [];

  factory WebitelSocket({required WebitelSocketConfig config}) {
    _instance.config = config;
    _instance._token = config.token;
    return _instance;
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
    logger.info('WebitelSocket: Connecting to ${config?.url}');
    _channel = WebSocketChannel.connect(Uri.parse(config?.url ?? ''));
    _wsSubscription = _channel.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );
    await _channel.ready;
    _isConnected = true;
    _startConnectivityMonitoring();
    _startPeriodicStateCheck();
  }

  void _startPeriodicStateCheck() {
    _stateCheckTimer?.cancel();
    _stateCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // logger.debug(
      //   '[PeriodicCheck] activeCalls=${_activeCalls.length}, '
      //   'postProcessing=${_postProcessing.length}, '
      //   'isRecording=$_screenRecordingActive',
      // );
      _updateScreenRecordingState(false);
    });
  }

  Future<void> disconnect() async {
    logger.info('WebitelSocket: Disconnecting...');
    _isConnected = false;
    _stateCheckTimer?.cancel();

    if (_screenRecordingActive) {
      _screenRecordingActive = false;
      logger.info(
        '[ScreenRecorder] Stopping screen recording due to disconnect...',
      );
      onScreenRecordStop?.call({'reason': 'socket_disconnect'});
      _onCallHangup?.call(_lastCallId ?? 'unknown');
    }

    // Close screen capturer if active
    _screenCapturer?.close('socket_disconnect');

    await _wsSubscription.cancel();
    await _channel.sink.close();
    _pendingRequests.clear();
    _outgoingQueue.clear();
    activeCalls.clear();
    _postProcessing.clear();
    await _connectivitySubscription.cancel();
  }

  Future<void> dispose() async {
    if (_screenRecordingActive) {
      _screenRecordingActive = false;
      logger.info(
        '[ScreenRecorder] Stopping screen recording due to dispose...',
      );
      onScreenRecordStop?.call({'reason': 'socket_dispose'});
      _onCallHangup?.call(_lastCallId ?? 'unknown');
    }

    _screenCapturer?.close('socket_dispose');

    await _agentStatusController.close();
    await _errorController.close();
    await _ackMessageController.close();
    await _wsSubscription.cancel();
    await _channel.sink.close();
    await _connectivitySubscription.cancel();
  }

  //917
  void _onMessage(dynamic message) async {
    logger.debug('WebitelSocket: Received message: $message');
    final Map<String, dynamic> data = jsonDecode(message);
    final storage = SecureStorageService();

    final agentId = data['data']?['agent_id'];
    if (agentId != null && agentId is int) {
      await storage.writeAgentId(agentId);
      logger.info('WebitelSocket: agent_id $agentId saved to storage');
    }

    final replySeq = data['seq_reply'];
    final event = fromString(data['event']);

    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      _handleReply(data, replySeq);
      return;
    }

    // --- CHECK SCREEN CONTROL PERMISSION ---
    bool screenControlEnabled = false;
    try {
      final token = await storage.readAccessToken();
      final agentId = await storage.readAgentId();

      if (token != null && agentId != null) {
        final agentsUri = Uri.parse(
          '${AppConfig.instance.baseUrl}/api/call_center/agents?page=1&size=1&fields=screen_control&id=$agentId',
        );

        final agentsResp = await http.get(
          agentsUri,
          headers: {'X-Webitel-Access': token},
        );

        if (agentsResp.statusCode == 200) {
          final js = jsonDecode(agentsResp.body);
          final items = js['items'];
          if (items is List && items.isNotEmpty) {
            final dynamic scValue = items.first['screen_control'];
            screenControlEnabled = scValue == true;
          }
        }
      }
    } catch (e, st) {
      logger.error('[WebitelSocket] Error fetching screen_control:', e, st);
    }

    // --- IGNORE EVENTS IF CONTROL DISABLED ---
    if (!screenControlEnabled) {
      if (event == WebSocketEvent.call || event == WebSocketEvent.channel) {
        logger.debug(
          '[WebitelSocket] Agent control disabled → ignoring ${data['event']}',
        );
        return;
      }
    }

    // --- HANDLE EVENTS ---
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
      case WebSocketEvent.channel:
        final channelData = data['data'];
        final channelType = channelData?['channel'];

        if (channelType == 'call' || channelType == 'out_call') {
          _handleChannelEvent(data);
        } else {
          logger.debug(
            'WebitelSocket: Ignored channel event of type $channelType',
          );
        }
        break;
      case WebSocketEvent.unknown:
        logger.debug('WebitelSocket: Unhandled event: ${data['event']}');
        break;
    }
  }

  void _handleChannelEvent(Map<String, dynamic> data) {
    final channel = data['data'];
    final status = channel['status'];

    final distribute = channel['distribute'] ?? {};
    final hasReporting = distribute['has_reporting'] == true;

    final attemptId = distribute['attempt_id'] ?? channel['attempt_id'];

    if (attemptId == null) {
      logger.debug('[ChannelEvent] No attemptId found, status=$status');
      _updateScreenRecordingState(false);
      return;
    }

    logger.debug('[ChannelEvent] attemptId=$attemptId, status=$status');

    if (hasReporting) {
      final existing = _postProcessing.any((c) => c['attempt_id'] == attemptId);

      if (!existing) {
        _postProcessing.add({
          'attempt_id': attemptId,
          'timestamp': channel['timestamp'],
        });
        logger.info('[PostProcessing] Added attempt $attemptId');
      }
    }

    if (status == 'missed' || status == 'waiting' || status == 'wrap_time') {
      final sizeBefore = _postProcessing.length;
      _postProcessing.removeWhere((c) => c['attempt_id'] == attemptId);
      final sizeAfter = _postProcessing.length;

      if (sizeBefore > sizeAfter) {
        logger.info('[PostProcessing] Removed attempt $attemptId ($status)');
      }
    }

    _updateScreenRecordingState(false);
  }

  String? _lastCallId;

  final _uuidRegExp = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  // Validates UUID according to RFC 4122 standard (universally unique identifier format),
  // supporting versions 1–5. Example format: 550e8400-e29b-41d4-a716-446655440000
  bool _isValidUuid(String id) {
    return _uuidRegExp.hasMatch(id);
  }

  void _handleCallEvent(Map<String, dynamic> data) {
    final call = data['data']?['call'];

    final callEvent = call['event'];
    final rawCallId = call['id']?.toString();
    final rawParentId = call['data']?['parent_id']?.toString();
    final attemptId = call['data']?['queue']?['attempt_id'];
    final recordScreen = call['data']['record_screen'] as bool? ?? false;

    final callId =
        (rawCallId != null && _isValidUuid(rawCallId)) ? rawCallId : null;
    final parentId =
        (rawParentId != null && _isValidUuid(rawParentId)) ? rawParentId : null;

    switch (callEvent) {
      case 'ringing':
      case 'update':
        if (callId != null
        //  && recordScreen
        ) {
          _screenRecordingActive = true;
          _onCallRinging?.call(parentId ?? callId);
          _lastCallId = callId;
          activeCalls.add({'callId': callId, 'attempt_id': attemptId});
          _updateScreenRecordingState(true);
        } else {
          logger.warn(
            'WebitelSocket: Received ringing event with invalid call id: $rawCallId',
          );
        }
        break;

      case 'hangup':
        if (callId != null) {
          activeCalls.removeWhere((c) => c['callId'] == callId);
          _updateScreenRecordingState(false);
        } else {
          logger.warn(
            'WebitelSocket: Received hangup event with invalid call id: $rawCallId',
          );
        }
        break;

      default:
        logger.debug('Unhandled callEvent: $callEvent');
    }
  }

  void _updateScreenRecordingState(bool record) {
    final shouldRecord = activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    if (shouldRecord && !_screenRecordingActive && record) {
      _screenRecordingActive = true;
      logger.info('[ScreenRecorder] Starting screen recording...');
      onScreenRecordStart?.call({'root_id': _lastCallId ?? 'unknown'});
    } else if (!shouldRecord && _screenRecordingActive) {
      _screenRecordingActive = false;
      logger.info('[ScreenRecorder] Stopping screen recording...');
      onScreenRecordStop?.call({'reason': 'no_active_calls_or_postprocessing'});

      _onCallHangup?.call(_lastCallId ?? 'unknown');
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

  //

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

  Future<void> _handleNotification(Map<String, dynamic> data) async {
    final notif = data['data']?['notification'];
    final actionStr = notif?['action'] as String?;
    final action = NotificationAction.fromString(actionStr);
    final body = Map<String, dynamic>.from(notif?['body'] ?? {});
    final ackId = body['ack_id'] as String?;

    String? ackError;

    try {
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
          if (_screenRecordingActive) {
            throw Exception('Screen recording already active from call');
          }
          onScreenRecordStart?.call(body);
          break;

        case NotificationAction.screenRecordStop:
          onScreenRecordStop?.call(body);
          break;

        case NotificationAction.unknown:
          logger.debug(
            '[WebitelSocket] Unknown notification action: $actionStr',
          );
          break;
      }
    } catch (e, st) {
      ackError = e.toString();
      logger.error('[WebitelSocket] Error handling notification', e, st);
    }

    if (ackId != null) {
      await ack(ackId, ackError);
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

    // Gracefully stop screen recording on error
    if (_screenRecordingActive) {
      _screenRecordingActive = false;
      logger.info(
        '[ScreenRecorder] Stopping screen recording due to socket error...',
      );
      onScreenRecordStop?.call({
        'reason': 'socket_error',
        'error': error.toString(),
      });
      _onCallHangup?.call(_lastCallId ?? 'unknown');
    }

    _screenCapturer?.close('socket_error');

    for (var c in _pendingRequests.values) {
      c.completeError(error);
    }
    _pendingRequests.clear();
    _outgoingQueue.clear();
    activeCalls.clear();
    _postProcessing.clear();
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

    // Gracefully stop screen recording when connection closes
    if (_screenRecordingActive) {
      _screenRecordingActive = false;
      logger.info(
        '[ScreenRecorder] Stopping screen recording due to connection close...',
      );
      onScreenRecordStop?.call({'reason': 'connection_closed'});
      _onCallHangup?.call(_lastCallId ?? 'unknown');
    }

    _screenCapturer?.close('connection_closed');
    activeCalls.clear();
    _postProcessing.clear();
    _isConnected = false;
    _reconnect();
  }

  void _startConnectivityMonitoring() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (results.contains(ConnectivityResult.none)) {
        if (_screenRecordingActive) {
          _screenRecordingActive = false;
          logger.info(
            '[ScreenRecorder] Stopping screen recording due to connectivity loss...',
          );
          onScreenRecordStop?.call({'reason': 'connectivity_lost'});
          _onCallHangup?.call(_lastCallId ?? 'unknown');
        }
        _screenCapturer?.close('connectivity_lost');
        activeCalls.clear();
        _postProcessing.clear();
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

  Future<void> ack(String id, String? err) async {
    final _ = await request(SocketActions.ack, {
      'ack_id': id,
      if (err != null) 'error': err,
    });
  }
}

class _QueuedRequest {
  final Map<String, dynamic> payload;

  _QueuedRequest(this.payload);
}
