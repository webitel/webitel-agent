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

  // Watchdog configuration
  Timer? _watchdogTimer;
  static const _watchdogInterval = Duration(seconds: 30);

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

  bool _appInitialized = false;

  void markAppInitialized() {
    _appInitialized = true;
  }

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

  /// Initiates the physical WebSocket connection.
  Future<void> connect() async {
    if (_connection.isConnected) return;
    if (config == null) {
      logger.error('[SOCKET] Connection aborted: Config missing');
      return;
    }
    await _connection.connect(config!.url);
  }

  /// Handles the full reconnection cycle (connect + auth).
  Future<void> _performFullReconnect(String source) async {
    logger.info('[SOCKET] RECONNECT_START | Source: $source');

    try {
      await connect();
      await authenticate();

      // Perform an immediate sync check after reconnection
      await _checkSyncStatus();

      // Refresh only basic agent data, no call synchronization.
      await getAgentSession();

      logger.info('[SOCKET] RECONNECT_SUCCESS');
    } catch (e) {
      logger.error('[SOCKET] RECONNECT_FAILED: $e');
    }
  }

  /// Authentication sequence.
  /// Closes the [_authGate] until 'hello' is received.
  Future<void> authenticate() async {
    if (_isAuthenticating) return;
    _isAuthenticating = true;

    try {
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

      await _authGate!.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () {
          logger.warn('[SOCKET] Auth gate timeout, proceeding...');
          if (_authGate?.isCompleted == false) _authGate?.complete();
        },
      );

      logger.info('[SOCKET] AUTH_COMPLETED');
      _startWatchdog(); // Start periodic sync checks
    } catch (e, st) {
      logger.error('[SOCKET] AUTH_FAILED: $e', e, st);
    } finally {
      _isAuthenticating = false;
    }
  }

  /// Starts a periodic background check to ensure the local recording state
  /// matches the actual server-side agent session.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      _watchdogInterval,
      (_) => _checkSyncStatus(),
    );
    logger.debug('[WATCHDOG] Periodic sync timer started (30s)');
  }

  /// Stops the periodic background check.
  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    logger.debug('[WATCHDOG] Periodic sync timer stopped');
  }

  /// Performs a manual synchronization check by fetching current active calls.
  /// Uses 'call_by_user' action to see if the user has any ongoing conversations.
  Future<void> _checkSyncStatus() async {
    // Only proceed if authenticated and connected
    if (!_connection.isConnected ||
        _authGate == null ||
        !_authGate!.isCompleted) {
      return;
    }

    try {
      // Request active calls for the current user
      // Action: 'call_by_user'
      final response = await request(SocketActions.callByUser);

      // The response usually contains a list of calls in 'items' or directly as a list
      // Based on Webitel API, we check if there are any entries
      final List? activeCalls = response['items'] as List?;
      final bool hasActiveCalls = activeCalls != null && activeCalls.isNotEmpty;

      // If our local state is 'active' but the server says there are no calls
      if (!hasActiveCalls && _callHandler.screenRecordingActive) {
        logger.warn(
          '[WATCHDOG] Out-of-sync! No active calls found via ${SocketActions.callByUser}. '
          'Terminating orphaned recording session.',
        );

        // Stop the recorder and clean up the handler
        _onRecordingStateChanged(false, null);
        _callHandler.clear();
      }
    } catch (e) {
      // Silence errors during watchdog to avoid log pollution during reconnects
      logger.error('[WATCHDOG] Active calls sync failed: $e');
    }
  }

  /// Main message router for incoming WebSocket frames.
  void _handleIncomingMessage(dynamic message) async {
    logger.debug('[SOCKET_RAW] << $message');

    final Map<String, dynamic> data = jsonDecode(message);
    final int? replySeq = data['seq_reply'];

    // Handle command replies
    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      _handleReply(data, replySeq);
      return;
    }

    final eventStr = data['event'] as String?;
    final event = eventFromString(eventStr);

    // Open the auth gate when server confirms session
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
        await _notificationHandler.handle(data);
        break;
      default:
        break;
    }
  }

  /// Callback triggered when CallHandler detects a state change that requires recording.
  void _onRecordingStateChanged(bool active, String? callId) {
    if (active) {
      final targetId = callId ?? 'active_session';
      if (_screenshotService?.isControlEnabled ?? false) {
        logger.info('[SOCKET] Triggering RECORD_START for $targetId');
        onScreenRecordStart?.call({'root_id': targetId});
      } else {
        logger.warn('[SOCKET] Permission denied for recording');
      }
    } else {
      logger.info('[SOCKET] Triggering RECORD_STOP');
      onScreenRecordStop?.call({'reason': 'session_ended'});
    }
  }

  /// Forces a clean transport reset.
  Future<void> _forceReconnect(String source) async {
    if (_isReconnecting) return;
    _isReconnecting = true;

    try {
      while (_isAuthenticating) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _connection.dispose();
      await Future.delayed(const Duration(milliseconds: 300));
      await _performFullReconnect(source);
    } finally {
      _isReconnecting = false;
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

  /// High-level request method with built-in auth gate waiting.
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? data,
  ]) async {
    if (action != SocketActions.authenticationChallenge && _authGate != null) {
      if (!_authGate!.isCompleted) await _authGate!.future;
    }
    return _sendRawRequest(action, data);
  }

  /// Low-level raw frame sender.
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

  /// Critical cleanup on physical disconnect.
  /// Forces any active recording to stop immediately to prevent ghost sessions.
  void _onDisconnected() {
    _stopWatchdog();
    logger.warn('[SOCKET] DISCONNECT_DETECTED | Cleaning up state...');

    // If a recording was active, stop it now. We assume network loss kills the session.
    if (_callHandler.screenRecordingActive) {
      logger.warn(
        '[SOCKET] DISCONNECT_CLEANUP: Stopping active recording due to link loss',
      );
      onScreenRecordStop?.call({'reason': 'network_loss_cleanup'});
      _callHandler.clear();
    }

    _isAuthenticating = false;

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

  /// Fetches basic agent session info.
  Future<AgentSession> getAgentSession() async {
    final response = await request(SocketActions.agentSession);
    final session = AgentSession.fromJson(response);
    if (session.agentId != 0 && _storage != null) {
      await _storage!.writeAgentId(session.agentId);
    }
    return session;
  }

  /// Graceful manual shutdown.
  Future<void> disconnect() async {
    logger.info('[SOCKET] MANUAL_DISCONNECT | Disposing manager');
    _stopWatchdog();
    _connection.dispose();
    _callHandler.clear();
    _notificationHandler.dispose();
  }

  /// Connectivity listener to handle OS-level network changes.
  void _setupConnectivity() {
    Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = !results.contains(ConnectivityResult.none);

      _networkDebounce?.cancel();

      _networkDebounce = Timer(const Duration(seconds: 1), () async {
        if (hasNetwork) {
          logger.info('[NETWORK] RESTORED: $results');

          if (!_appInitialized) {
            logger.debug('[NETWORK] IGNORE | app initializing');
            return;
          }

          await _forceReconnect('NETWORK_RESTORED');
        } else {
          logger.warn('[NETWORK] LOST');
          // Note: Local cleanup is handled via _onDisconnected callback from WsConnectionManager
        }
      });
    });
  }

  bool _isReconnecting = false;
  Timer? _networkDebounce;

  void updateToken(String newToken) => _token = newToken;
}
