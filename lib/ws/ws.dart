// socket/webitel_socket.dart

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webitel_agent_flutter/service/control/agent_control.dart';
import 'package:webitel_agent_flutter/service/streaming/webrtc_streamer.dart';
import 'package:webitel_agent_flutter/ws/ws_config.dart';

import '../core/logger.dart';
import '../service/screenshot/screenshot_sender.dart';
import '../service/system/tray.dart';
import '../model/agent.dart';
import '../model/auth.dart';
import 'ws_error.dart';

enum AgentStatus { online, offline, pause, unknown }

enum WebSocketEvent { agentStatus, hello, call, notification, channel, unknown }

WebSocketEvent fromString(String? value) {
  switch (value) {
    case 'agent_status':
      return WebSocketEvent.agentStatus;
    case 'hello':
      return WebSocketEvent.hello;
    case 'call':
      return WebSocketEvent.call;
    case 'notification':
      return WebSocketEvent.notification;
    case 'channel':
      return WebSocketEvent.channel;
    default:
      return WebSocketEvent.unknown;
  }
}

enum NotificationAction {
  screenShare,
  screenshot,
  screenRecordStart,
  screenRecordStop,
  unknown;

  static NotificationAction fromString(String? action) {
    switch (action) {
      case 'screen_share':
        return NotificationAction.screenShare;
      case 'screenshot':
        return NotificationAction.screenshot;
      case 'ss_record_start':
        return NotificationAction.screenRecordStart;
      case 'ss_record_stop':
        return NotificationAction.screenRecordStop;
      default:
        return NotificationAction.unknown;
    }
  }
}

class SocketActions {
  static const authenticationChallenge = 'authentication_challenge';
  static const agentSession = 'cc_agent_session';
  static const userDefaultDevice = 'user_default_device';
  static const agentOnline = 'cc_agent_online';
  static const agentOffline = 'cc_agent_offline';
  static const agentPause = 'cc_agent_pause';
  static const ack = 'ss_ack';
}

class WebitelSocket {
  final AgentControlService agentControlService;
  final WebitelSocketConfig config;
  late String _token;

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

  bool get _shouldRecordScreen =>
      activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

  WebitelSocket({required this.config, required this.agentControlService}) {
    _token = config.token;
    screenshotService = ScreenshotSenderService(baseUrl: config.baseUrl);
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

  //917
  void _onMessage(dynamic message) async {
    logger.debug('WebitelSocket: Received message: $message');

    final Map<String, dynamic> data = jsonDecode(message);
    final replySeq = data['seq_reply'];
    final event = fromString(data['event']);

    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      _handleReply(data, replySeq);
      return;
    }

    if (!agentControlService.screenControlEnabled) {
      if (event == WebSocketEvent.call || event == WebSocketEvent.channel) {
        logger.debug(
          '[WebitelSocket] Agent control disabled → ignoring ${data['event']}',
        );
        return;
      }
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
        if (callId != null && recordScreen) {
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
    } catch (e) {
      ackError = e.toString();
      logger.error('[WebitelSocket] Error handling notification', e);
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
    for (var c in _pendingRequests.values) {
      c.completeError(error);
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
