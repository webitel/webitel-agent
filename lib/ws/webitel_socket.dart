import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';

import '../core/logger/logger.dart';
import 'model/agent.dart';
import '../service/screenshot/sender.dart';
import 'core/config.dart';
import 'core/constants.dart';
import 'core/connection_manager.dart';
import 'core/error.dart';
import 'handlers/call_handler.dart';
import 'handlers/notification_handler.dart';

class WebitelSocket {
  static final WebitelSocket _instance = WebitelSocket._internal();
  static WebitelSocket get instance => _instance;

  late final WsConnectionManager _connection;
  late final CallHandler _callHandler;
  late NotificationHandler _notificationHandler;

  IStorageService? _storage;
  ScreenshotSenderService? _screenshotService;

  WebitelSocketConfig? config;
  String? _token;

  final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};
  final _outgoingQueue = Queue<Map<String, dynamic>>();

  int _seq = 1;
  bool _isSending = false;

  Completer<void>? _authGate;
  bool _isAuthenticating = false;

  final _agentStatusController = StreamController<String>.broadcast();
  Stream<String> get agentStatusStream => _agentStatusController.stream;

  void Function(Map<String, dynamic> body)? onScreenRecordStart;
  void Function(Map<String, dynamic> body)? onScreenRecordStop;

  WebitelSocket._internal() {
    _callHandler = CallHandler();
    _connection = WsConnectionManager(
      onMessage: _handleIncomingMessage,
      onDisconnected: _onDisconnected,
    );
    _notificationHandler = NotificationHandler(
      screenshotService: null,
      requestExecutor: request,
    );
    _setupConnectivity();
  }

  factory WebitelSocket({
    required WebitelSocketConfig config,
    required IStorageService storage,
  }) {
    _instance.config = config;
    _instance._token = config.token;
    _instance._storage = storage;
    return _instance;
  }

  Future<void> get ready => _connection.ready;

  void initServices({
    required ScreenshotSenderService screenshot,
    required IStorageService storage,
  }) {
    _storage = storage;
    _screenshotService = screenshot;
    _notificationHandler = NotificationHandler(
      screenshotService: screenshot,
      requestExecutor: request,
    );
    _notificationHandler.onScreenRecordStart =
        (body) => onScreenRecordStart?.call(body);
    _notificationHandler.onScreenRecordStop =
        (body) => onScreenRecordStop?.call(body);
  }

  /// [LOGIC] Initiates physical connection.
  Future<void> connect() async {
    if (_connection.isConnected) return;
    if (config == null) {
      logger.error('[SOCKET] Connection aborted: Config missing');
      return;
    }
    await _connection.connect(config!.url);
  }

  /// [LOGIC] Centralized Reconnection Sequence
  /// [GUARD] Prevents multiple concurrent reconnection attempts
  Future<void> _performFullReconnect(String source) async {
    if (_isAuthenticating) {
      logger.warn(
        '[SOCKET] Reconnect ($source) skipped: Already authenticating',
      );
      return;
    }

    logger.info('[SOCKET] STARTING RECONNECT SEQUENCE | Source: $source');
    try {
      await connect();
      await authenticate();
      logger.info('[SOCKET] RECONNECT SUCCESSFUL | Source: $source');
    } catch (e) {
      logger.error('[SOCKET] RECONNECT FAILED | Source: $source | Error: $e');
    }
  }

  /// [LOGIC] Authentication sequence.
  /// [GUARD] Waits for physical connection ready state before sending challenge.
  Future<void> authenticate() async {
    if (_isAuthenticating) return;
    _isAuthenticating = true;

    try {
      // [GUARD] Ensure the physical channel is established
      await _connection.ready.timeout(const Duration(seconds: 5));

      if (!_connection.isConnected) {
        logger.warn('[SOCKET] Aborting auth: connection not active');
        return;
      }

      logger.info('[SOCKET] AUTH_START (Gate Closed)');
      _authGate = Completer<void>();

      await _sendRawRequest(SocketActions.authenticationChallenge, {
        'token': _token,
      });

      // [GUARD] Wait for server 'hello' event or timeout
      await _authGate!.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () {
          logger.warn('[SOCKET] Auth gate timeout, proceeding...');
          if (_authGate?.isCompleted == false) _authGate?.complete();
        },
      );

      // [LOGIC] Buffer to let server process the session
      await Future.delayed(const Duration(milliseconds: 500));
      await _syncActiveState();
    } catch (e, st) {
      logger.error('[SOCKET] AUTH_FAILED: $e', e, st);
    } finally {
      _isAuthenticating = false;
    }
  }

  Future<void> _syncActiveState() async {
    try {
      logger.info('[SOCKET] SYNC: Requesting active calls...');
      final callResp = await request(SocketActions.callByUser);
      final List? calls = callResp['items'];

      if (calls != null && calls.isNotEmpty) {
        for (var call in calls) {
          logger.info('[SOCKET] SYNC: Re-injecting call ${call['id']}');
          _handleIncomingMessage(
            jsonEncode({
              'event': 'call',
              'data': {'call': call},
            }),
          );
        }
      } else {
        logger.info('[SOCKET] SYNC: No active calls.');
        if (_callHandler.activeCalls.isNotEmpty ||
            _callHandler.screenRecordingActive) {
          logger.warn('[SOCKET] SYNC_CLEANUP: Forcing stop.');
          _callHandler.clear();
          onScreenRecordStop?.call({
            'reason': 'no_active_calls_after_reconnect',
          });
        }
      }
      await getAgentSession();
    } catch (e) {
      logger.warn('[SOCKET] SYNC_ERROR: $e');
    }
  }

  void _handleIncomingMessage(dynamic message) async {
    logger.debug('[SOCKET_RAW] << $message');

    final Map<String, dynamic> data = jsonDecode(message);
    final int? replySeq = data['seq_reply'];

    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      _handleReply(data, replySeq);
      return;
    }

    final eventStr = data['event'] as String?;
    final event = eventFromString(eventStr);

    // [LOGIC] Open the gate when server says hello
    if (event == WebSocketEvent.hello && _authGate?.isCompleted == false) {
      logger.info('[SOCKET] Auth Gate OPENED (Hello Received)');
      _authGate?.complete();
    }

    switch (event) {
      case WebSocketEvent.agentStatus:
        final status = data['data']?['status']?.toString();
        if (status != null) _agentStatusController.add(status);
        break;
      case WebSocketEvent.call:
        _callHandler.handleCallEvent(data, _onRecordingStateChanged);
        break;
      case WebSocketEvent.channel:
        _callHandler.handleChannelEvent(data, _onRecordingStateChanged);
        break;
      case WebSocketEvent.notification:
        if (!(_screenshotService?.isControlEnabled ?? false)) return;
        _notificationHandler.isRecordingFromCall =
            _callHandler.screenRecordingActive;
        await _notificationHandler.handle(data);
        break;
      default:
        break;
    }
  }

  void _onRecordingStateChanged(bool active, String? callId) {
    if (active) {
      if (_screenshotService?.isControlEnabled ?? false) {
        logger.info('[SOCKET] RECORD_START: Permission granted for $callId');
        onScreenRecordStart?.call({'root_id': callId ?? 'unknown'});
      } else {
        logger.warn('[SOCKET] RECORD_BLOCKED: No permission');
      }
    } else {
      logger.info('[SOCKET] RECORD_STOP: Finalizing');
      onScreenRecordStop?.call({'reason': 'session_ended'});
    }
  }

  void _handleReply(Map<String, dynamic> data, int seq) {
    final status = data['status'] ?? 'UNKNOWN';
    final completer = _pendingRequests.remove(seq);
    if (status == 'OK') {
      completer?.complete(data['data'] ?? data);
    } else {
      completer?.completeError(SocketError.fromJson(data['error'] ?? {}));
    }
  }

  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? data,
  ]) async {
    if (action != SocketActions.authenticationChallenge && _authGate != null) {
      if (!_authGate!.isCompleted) await _authGate!.future;
    }
    return _sendRawRequest(action, data);
  }

  Future<Map<String, dynamic>> _sendRawRequest(
    String action, [
    Map<String, dynamic>? data,
    int retryCount = 0,
  ]) async {
    final currentSeq = _seq++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[currentSeq] = completer;
    final payload = {
      'seq': currentSeq,
      'action': action,
      if (data != null) 'data': data,
    };
    _outgoingQueue.add(payload);
    _startSendLoop();
    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      _pendingRequests.remove(currentSeq);
      if (e is SocketError && retryCount < 2) {
        await Future.delayed(Duration(milliseconds: 1000 * (retryCount + 1)));
        return _sendRawRequest(action, data, retryCount + 1);
      }
      rethrow;
    }
  }

  void _startSendLoop() {
    if (_isSending) return;
    _isSending = true;
    Future.doWhile(() async {
      if (_outgoingQueue.isEmpty || !_connection.isConnected) {
        _isSending = false;
        return false;
      }
      _connection.send(_outgoingQueue.removeFirst());
      await Future.delayed(const Duration(milliseconds: 5));
      return true;
    });
  }

  /// [LOGIC] Cleanup on disconnect.
  void _onDisconnected() {
    logger.warn('[SOCKET] DISCONNECT_DETECTED | Cleaning up state...');

    _isAuthenticating = false;

    // [GUARD] Ensure the gate is not hanging if connection drops
    if (_authGate != null && !_authGate!.isCompleted) {
      _authGate!.completeError(
        SocketError(detail: 'Disconnected', code: 0, id: '', status: 'FAIL'),
      );
    }
    _authGate = null;

    _isSending = false;
    for (var c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError(
          SocketError(detail: 'Disconnected', code: 0, id: '', status: ''),
        );
      }
    }
    _pendingRequests.clear();
    _outgoingQueue.clear();

    final retryDelay = _connection.getNextRetryDelay();
    logger.info('[SOCKET] RETRY_TIMER | Scheduled in ${retryDelay.inSeconds}s');

    Future.delayed(retryDelay, () async {
      if (!_connection.isConnected) {
        await _performFullReconnect('RETRY_TIMER');
      }
    });
  }

  Future<AgentSession> getAgentSession() async {
    final response = await request(SocketActions.agentSession);
    final session = AgentSession.fromJson(response);
    if (session.agentId != 0 && _storage != null) {
      await _storage!.writeAgentId(session.agentId);
    }
    return session;
  }

  Future<void> disconnect() async {
    logger.info('[SOCKET] MANUAL_DISCONNECT | Disposing manager');
    _connection.dispose();
    _callHandler.clear();
    _notificationHandler.dispose();
  }

  void _setupConnectivity() {
    Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = !results.contains(ConnectivityResult.none);

      if (hasNetwork) {
        logger.info('[NETWORK] STATUS: RESTORED | Connectivity: $results');
        if (!_connection.isConnected) {
          _performFullReconnect('NETWORK_RESTORED');
        }
      } else {
        logger.warn('[NETWORK] STATUS: LOST | Internet connection unavailable');
      }
    });
  }

  void updateToken(String newToken) => _token = newToken;
}
