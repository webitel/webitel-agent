import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
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

/// WebSocket connection manager for Webitel desktop app.
///
/// Responsibilities:
/// - Manages WebSocket lifecycle (connect, authenticate, disconnect)
/// - Routes incoming events to appropriate handlers
/// - Maintains request-reply correlation via sequence numbers
/// - Handles network availability changes with debouncing
///
/// Thread safety: All state mutations are serialized through async callbacks.
class WebitelSocket {
  static final WebitelSocket _instance = WebitelSocket._internal();
  static WebitelSocket get instance => _instance;

  // ============================================================================
  // Core Components
  // ============================================================================

  late final WsConnectionManager _connection;
  late final CallHandler _callHandler;
  late NotificationHandler _notificationHandler;

  IStorageService? _storage;
  ScreenshotSenderService? _screenshotService;

  // ============================================================================
  // Configuration & Authentication
  // ============================================================================

  WebitelSocketConfig? config;
  String? _token;

  /// Gates all non-auth requests until 'hello' is received from server.
  /// Ensures auth completes before business logic proceeds.
  Completer<void>? _authGate;
  Future<void>? _authFuture;

  // ============================================================================
  // Request Management
  // ============================================================================

  /// Maps sequence number -> pending request completer.
  /// Correlates replies to requests for RPC-style communication.
  final _pendingRequests = <int, Completer<Map<String, dynamic>>>{};

  /// Outgoing message queue. Processed serially by _startSendLoop().
  final _outgoingQueue = Queue<Map<String, dynamic>>();

  /// Current request sequence number. Increments with each request.
  int _seq = 1;

  /// Lock to ensure single sender coroutine processes the queue.
  bool _isSending = false;

  // ============================================================================
  // Streams & Callbacks
  // ============================================================================

  /// Broadcasts agent status changes (e.g., 'online', 'offline', 'busy').
  final _agentStatusController = StreamController<String>.broadcast();
  Stream<String> get agentStatusStream => _agentStatusController.stream;

  /// External callbacks for recording lifecycle events.
  /// Called when recording should START (valid callId + permissions granted).
  Future<bool> Function(Map<String, dynamic> body)? onScreenRecordStart;

  /// Called when recording should STOP (all calls/post-processing ended).
  Future<void> Function(Map<String, dynamic> body)? onScreenRecordStop;

  // Starts a recording only if none is running (recovery after a lost recorder).
  Future<bool> Function(Map<String, dynamic> body)? onScreenRecordEnsure;

  // The server refused the token on a reconnect: a new login is needed.
  void Function()? onAuthRejected;

  // ============================================================================
  // Lifecycle Flags
  // ============================================================================

  /// Prevents multiple reconnect attempts in parallel.
  bool _isReconnecting = false;

  /// Guards against network debounce race conditions.
  Timer? _networkDebounce;

  /// Prevents reconnect actions before app initialization is complete.
  bool _appInitialized = false;

  // Set by disconnect(): nothing may reconnect until the next connect().
  bool _shutdown = false;
  Timer? _retryTimer;

  // A WS drop does not stop the WebRTC recording: within this window the call
  // state is re-checked after reconnect instead of cutting the recording.
  @visibleForTesting
  static Duration recordingGrace = const Duration(seconds: 60);
  Timer? _recordingGraceTimer;

  String? _recordingId;
  bool _recordingLost = false;
  final _recoveryAttempts = <String, int>{};
  static const maxRecoveryAttempts = 3;
  Timer? _recoveryTimer;

  // After a reconnect the call state may be stale (a hangup lost in the gap),
  // so while recording the agent session is re-checked until it goes idle.
  static const staleCallCheck = Duration(seconds: 30);
  Timer? _staleCallTimer;

  /// Holds the callId when recording start was blocked by missing permission.
  /// Cleared when permission is granted or the call ends.
  String? _pendingPermissionCallId;
  Timer? _permissionRetryTimer;

  // ============================================================================
  // Singleton Pattern
  // ============================================================================

  WebitelSocket._internal() {
    _callHandler = CallHandler();
    _connection = WsConnectionManager(
      onMessage: _handleIncomingMessage,
      onDisconnected: _onDisconnected,
    );
    _notificationHandler = NotificationHandler(
      screenshotService: null,
      requestExecutor: request,
      callHandler: _callHandler,
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

  /// Future that completes when the WebSocket transport is ready.
  Future<void> get ready => _connection.ready;

  // ============================================================================
  // Initialization
  // ============================================================================

  /// Marks that the app has finished initialization.
  /// Used to prevent auto-reconnects before UI setup is complete.
  void markAppInitialized() {
    _appInitialized = true;
  }

  /// Initializes optional services (screenshot capture, storage persistence).
  /// Called after constructor, allows late binding of dependencies.
  void initServices({
    required ScreenshotSenderService screenshot,
    required IStorageService storage,
  }) {
    _storage = storage;
    _screenshotService = screenshot;
    _notificationHandler = NotificationHandler(
      screenshotService: screenshot,
      requestExecutor: request,
      callHandler: _callHandler,
    );
    _notificationHandler.onScreenRecordStart =
        (body) async => await onScreenRecordStart?.call(body) ?? false;
    _notificationHandler.onScreenRecordStop =
        (body) async => await onScreenRecordStop?.call(body);
  }

  // ============================================================================
  // Connection Lifecycle
  // ============================================================================

  /// Initiates the physical WebSocket connection to the server.
  /// No-op if already connected.
  Future<void> connect() async {
    _shutdown = false;
    if (_connection.isConnected) return;
    if (config == null) {
      throw SocketUnavailableException('config missing');
    }
    await _connection.connect(config!.url);
  }

  Future<void> _performFullReconnect(String source) async {
    if (_shutdown) return;
    logger.info('[SOCKET] RECONNECT_START | Source: $source');

    int? generation;
    try {
      await connect();
      generation = _connection.generation;
      await authenticate();
      logger.info('[SOCKET] RECONNECT_SUCCESS');
      await _resyncAfterReconnect(generation);
    } on AuthRejectedException catch (e) {
      logger.error('[SOCKET] RECONNECT_FAILED: $e');
      if (!_shutdown) onAuthRejected?.call();
    } catch (e) {
      logger.error('[SOCKET] RECONNECT_FAILED: $e');
      if (_shutdown) return;
      if (_connection.isConnected && _connection.generation == generation) {
        // Connected but not authenticated gets no events: drop it, which
        // schedules the next attempt.
        _connection.drop('AUTH_FAILED');
      } else if (!_connection.isConnected) {
        _scheduleRetry();
      }
    }
  }

  // AuthRejectedException: the server refused the token.
  // SocketUnavailableException: it could not be reached. Callers share one attempt.
  Future<void> authenticate() {
    final inFlight = _authFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> attempt;
    attempt = _authenticate().whenComplete(() {
      if (identical(_authFuture, attempt)) _authFuture = null;
    });
    _authFuture = attempt;
    return attempt;
  }

  Future<void> _authenticate() async {
    try {
      await _connection.ready.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw SocketUnavailableException('transport not ready');
    }
    if (!_connection.isConnected) {
      throw SocketUnavailableException('not connected');
    }

    logger.info('[SOCKET] AUTH_START (Gate Closed)');
    final gate = Completer<void>();
    // Only queued requests await the gate; its failure must not surface as an
    // unhandled error when none are waiting.
    gate.future.ignore();
    _authGate = gate;

    try {
      await _sendRawRequest(SocketActions.authenticationChallenge, {
        'token': _token,
      });
    } on SocketError catch (e) {
      if (!gate.isCompleted) gate.completeError(e);
      // Only an explicit refusal means the token is bad; anything else (server
      // restarting, internal error, our own code-0 "Disconnected") is transient.
      if (e.code == 401 || e.code == 403) throw AuthRejectedException(e);
      throw SocketUnavailableException(e.toString());
    } on TimeoutException {
      if (!gate.isCompleted) gate.completeError(TimeoutException('auth'));
      throw SocketUnavailableException('no reply to authentication');
    }

    // An OK reply to the challenge means the session is authenticated; the
    // 'hello' event may come before or after it.
    if (!gate.isCompleted) gate.complete();
    logger.info('[SOCKET] AUTH_COMPLETED');
  }

  // ============================================================================
  // Message Routing
  // ============================================================================

  /// Main router for all incoming WebSocket messages.
  ///
  /// Flow:
  /// 1. Parse JSON
  /// 2. If reply to previous request -> resolve pending completer
  /// 3. If event -> route to appropriate handler (call, channel, notification, etc)
  /// 4. Special case: 'hello' opens auth gate
  void _handleIncomingMessage(dynamic message) async {
    logger.debug('[SOCKET_RAW] << $message');

    final Map<String, dynamic> data = jsonDecode(message);
    final int? replySeq = data['seq_reply'];

    // ========================================================================
    // Route 1: Reply to a previous request
    // ========================================================================
    if (replySeq != null && _pendingRequests.containsKey(replySeq)) {
      _handleReply(data, replySeq);
      return;
    }

    // ========================================================================
    // Route 2: Event from server
    // ========================================================================
    final eventStr = data['event'] as String?;
    final event = eventFromString(eventStr);

    // Special: server confirms auth is valid
    if (event == WebSocketEvent.hello && _authGate?.isCompleted == false) {
      logger.info('[SOCKET] Auth Gate OPENED (Hello Received)');
      _authGate?.complete();
    }

    // Route to specific handlers
    switch (event) {
      case WebSocketEvent.agentStatus:
        _handleAgentStatusEvent(data);
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

  /// Extracts and broadcasts agent status (e.g., 'online', 'offline', 'busy').
  void _handleAgentStatusEvent(Map<String, dynamic> data) {
    final status = data['data']?['status']?.toString();
    if (status != null) {
      _agentStatusController.add(status);
    }
  }

  // ============================================================================
  // Recording State Management
  // ============================================================================

  /// Called by CallHandler when recording state transitions.
  ///
  /// START conditions:
  /// - [active] == true
  /// - [callId] is not null (we have a valid call context)
  /// - Screenshot service is enabled (permission check)
  ///
  /// STOP conditions:
  /// - [active] == false
  /// - Fires unconditionally (no callId needed)
  ///
  /// Guarantees:
  /// - No "fake" recordings (invalid callIds are rejected)
  /// - Exactly one START per valid session
  /// - Exactly one STOP per session
  void _onRecordingStateChanged(bool active, String? callId) {
    if (active) {
      if (callId == null) {
        logger.warn(
          '[SOCKET] RECORD_START skipped: missing callId '
          '(likely post-processing only, call will be recorded after hangup)',
        );
        return;
      }

      if (!(_screenshotService?.isControlEnabled ?? false)) {
        logger.warn(
          '[SOCKET] RECORD_START blocked: permission denied (callId=$callId) — scheduling retry',
        );
        _pendingPermissionCallId = callId;
        _permissionRetryTimer ??= Timer.periodic(const Duration(seconds: 5), (
          _,
        ) {
          if (!_callHandler.screenRecordingActive) {
            _permissionRetryTimer?.cancel();
            _permissionRetryTimer = null;
            _pendingPermissionCallId = null;
            return;
          }
          if (_screenshotService?.isControlEnabled ?? false) {
            _permissionRetryTimer?.cancel();
            _permissionRetryTimer = null;
            final id = _pendingPermissionCallId!;
            _pendingPermissionCallId = null;
            logger.info(
              '[SOCKET] RECORD_START (retry after permission) | callId=$id',
            );
            onScreenRecordStart?.call({'root_id': id, 'source': 'call_event'});
          }
        });
        return;
      }

      _permissionRetryTimer?.cancel();
      _permissionRetryTimer = null;
      _pendingPermissionCallId = null;
      _recordingId = callId;
      _recordingLost = false;
      logger.info('[SOCKET] RECORD_START | callId=$callId');
      onScreenRecordStart?.call({'root_id': callId, 'source': 'call_event'});
    } else {
      _permissionRetryTimer?.cancel();
      _permissionRetryTimer = null;
      _pendingPermissionCallId = null;
      _clearRecordingTracking();
      logger.info('[SOCKET] RECORD_STOP | reason=session_ended');
      onScreenRecordStop?.call({'reason': 'session_ended'});
    }
  }

  // ============================================================================
  // Reconnection
  // ============================================================================

  /// Forces a complete transport reset and full reconnection.
  ///
  /// Waits for any in-flight auth to complete, then disposes connection
  /// and queues a full reconnect cycle.
  ///
  /// Used when:
  /// - Network is restored
  /// - Connection is stuck/unresponsive
  Future<void> _forceReconnect(String source) async {
    if (_isReconnecting || _shutdown) return;
    _isReconnecting = true;
    _retryTimer?.cancel();

    try {
      try {
        await _authFuture;
      } catch (_) {}

      // Dispose old connection.
      _connection.dispose();

      // Brief delay before reconnecting (prevents thundering herd).
      await Future.delayed(const Duration(milliseconds: 300));

      // Full reconnect cycle.
      await _performFullReconnect(source);
    } finally {
      _isReconnecting = false;
    }
  }

  // ============================================================================
  // Request/Reply Correlation
  // ============================================================================

  /// Handles a reply from server to a previous request.
  ///
  /// Resolves or rejects the pending completer based on status code.
  void _handleReply(Map<String, dynamic> data, int seq) {
    final status = data['status'] ?? 'UNKNOWN';
    final completer = _pendingRequests.remove(seq);

    if (status == 'OK') {
      completer?.complete(data['data'] ?? data);
    } else {
      completer?.completeError(SocketError.fromJson(data['error'] ?? {}));
    }
  }

  // ============================================================================
  // High-Level API
  // ============================================================================

  /// High-level request method.
  ///
  /// Waits for auth to complete (unless this IS the auth request) before
  /// sending the actual request.
  ///
  /// Retries up to 2 times on SocketError with exponential backoff.
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? data,
  ]) async {
    // Non-auth requests wait for auth gate to open.
    if (action != SocketActions.authenticationChallenge && _authGate != null) {
      if (!_authGate!.isCompleted) await _authGate!.future;
    }
    return _sendRawRequest(action, data);
  }

  // ============================================================================
  // Low-Level API
  // ============================================================================

  /// Low-level raw frame sender with automatic retry logic.
  ///
  /// Assigns a unique sequence number, queues the payload, and returns a
  /// future that resolves when the reply arrives or timeout occurs.
  ///
  /// Retries:
  /// - Max 2 retries on SocketError
  /// - Exponential backoff: 1s, 2s
  /// - Other exceptions fail immediately
  ///
  /// [retryCount] - Internal use only, incremented on retry.
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
      // Wait for reply with 15 second timeout.
      return await completer.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      _pendingRequests.remove(currentSeq);

      // Retry logic: SocketError only, with exponential backoff.
      // code 0 is our own "Disconnected": retrying on the dead socket only delays.
      if (e is SocketError && e.code != 0 && retryCount < 2) {
        final delay = Duration(milliseconds: 1000 * (retryCount + 1));
        await Future.delayed(delay);
        return _sendRawRequest(action, data, retryCount + 1);
      }

      rethrow;
    }
  }

  /// Starts the send loop if not already running.
  ///
  /// Dequeues messages one-by-one and sends via connection.
  /// Runs serially (5ms delay between sends to avoid overwhelming server).
  void _startSendLoop() {
    if (_isSending) return;
    _isSending = true;

    Future.doWhile(() async {
      // Stop condition: queue empty or connection lost
      if (_outgoingQueue.isEmpty || !_connection.isConnected) {
        _isSending = false;
        return false;
      }

      _connection.send(_outgoingQueue.removeFirst());

      // Small delay to serialize sends (server may have limits).
      await Future.delayed(const Duration(milliseconds: 5));
      return true;
    });
  }

  // ============================================================================
  // Disconnect Handling
  // ============================================================================

  /// Critical cleanup handler called when WebSocket connection drops.
  ///
  /// Responsibilities:
  /// - Force-stop any active recording (prevents ghost sessions)
  /// - Fail all pending requests
  /// - Clear state
  /// - Schedule retry with exponential backoff
  ///
  /// This is the most critical method for preventing ghost recordings.
  void _onDisconnected() {
    logger.warn('[SOCKET] DISCONNECT_DETECTED | Cleaning up state...');

    if (_callHandler.screenRecordingActive && !_shutdown) {
      logger.warn(
        '[SOCKET] Recording kept for ${recordingGrace.inSeconds}s while reconnecting',
      );
      // Cancelled by a successful resync; firing means none happened in time.
      _recordingGraceTimer ??= Timer(recordingGrace, () {
        _recordingGraceTimer = null;
        _stopRecordingAfterLinkLoss('network_loss_cleanup');
      });
    }

    _failPending('Disconnected');
    _staleCallTimer?.cancel();
    _staleCallTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_shutdown) return;
    final retryDelay = _connection.getNextRetryDelay();
    logger.info('[SOCKET] RETRY_TIMER | Scheduled in ${retryDelay.inSeconds}s');

    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () {
      if (_shutdown || _isReconnecting || _connection.isConnected) return;
      _performFullReconnect('RETRY_TIMER');
    });
  }

  void _clearRecordingTracking() {
    _recordingId = null;
    _recordingLost = false;
    _recoveryAttempts.clear();
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _staleCallTimer?.cancel();
    _staleCallTimer = null;
  }

  // The recorder died on its own (ICE failure, network loss) while the call
  // may still be going: start it again, now or after the next resync.
  void notifyRecordingLost(String id) {
    if (_shutdown || !_callHandler.screenRecordingActive) return;
    _recordingId ??= id;
    _recordingLost = true;
    if (_connection.isConnected && _recordingGraceTimer == null) {
      _scheduleRecovery();
    }
  }

  void _scheduleRecovery() {
    final id = _recordingId;
    if (id == null || !_recordingLost) return;
    final attempts = _recoveryAttempts[id] ?? 0;
    if (attempts >= maxRecoveryAttempts) {
      logger.error(
        '[SOCKET] Recording $id lost; giving up after $attempts restarts',
      );
      return;
    }
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(Duration(seconds: 5 * (attempts + 1)), () async {
      _recoveryTimer = null;
      if (_shutdown || !_callHandler.screenRecordingActive) return;
      if (_recordingId != id || !_recordingLost) return;
      // Offline or waiting for a resync: don't spend an attempt, the resync
      // after reconnect restarts it.
      if (!_connection.isConnected || _recordingGraceTimer != null) return;
      _recoveryAttempts[id] = attempts + 1;
      logger.warn(
        '[SOCKET] Restarting lost recording $id (attempt ${attempts + 1})',
      );
      final ok = await onScreenRecordEnsure?.call({'root_id': id}) ?? false;
      if (ok) {
        _recordingLost = false;
      } else {
        _scheduleRecovery();
      }
    });
  }

  void _failPending(String reason) {
    _authFuture = null;
    if (_authGate != null && !_authGate!.isCompleted) {
      _authGate!.completeError(
        SocketError(detail: reason, code: 0, id: '', status: 'FAIL'),
      );
    }
    _authGate = null;

    _isSending = false;
    for (var c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError(
          SocketError(detail: reason, code: 0, id: '', status: ''),
        );
      }
    }
    _pendingRequests.clear();
    _outgoingQueue.clear();
  }

  void _stopRecordingAfterLinkLoss(String reason) {
    if (!_callHandler.screenRecordingActive) return;
    logger.warn('[SOCKET] Stopping recording: $reason');
    _callHandler.clear();
    _clearRecordingTracking();
    onScreenRecordStop?.call({'reason': reason});
  }

  Future<void> _resyncAfterReconnect(int generation) async {
    try {
      _resyncRecording(await getAgentSession());
    } catch (e) {
      // Dropped again meanwhile: the grace timer of that drop stays in charge.
      if (!_connection.isConnected || _connection.generation != generation) {
        return;
      }
      // The connection is authenticated and delivers events: keep it. Without a
      // session the call state can't be confirmed, so keep the recording and let
      // the periodic check decide.
      logger.warn('[SOCKET] Agent session unavailable after reconnect: $e');
      if (!_callHandler.screenRecordingActive) return;
      _recordingGraceTimer?.cancel();
      _recordingGraceTimer = null;
      _scheduleRecovery();
      _staleCallTimer?.cancel();
      _staleCallTimer = Timer.periodic(
        staleCallCheck,
        (_) => _checkStaleCall(),
      );
    }
  }

  // Call events sent while the socket was down are lost, so after a reconnect
  // the agent session decides whether the recorded call is still going.
  void _resyncRecording(AgentSession session) {
    final grace = _recordingGraceTimer;
    _recordingGraceTimer = null;
    grace?.cancel();
    if (!_callHandler.screenRecordingActive) return;

    if (!_isCallBusy(session)) {
      _stopRecordingAfterLinkLoss('call_ended_while_disconnected');
      return;
    }
    logger.info(
      '[SOCKET] Recording continues after reconnect: call still active',
    );
    _scheduleRecovery();
    _staleCallTimer?.cancel();
    _staleCallTimer = Timer.periodic(staleCallCheck, (_) => _checkStaleCall());
  }

  bool _isCallBusy(AgentSession session) {
    // Manual outbound calls and their post-processing live on 'out_call'.
    const callChannels = {'call', 'out_call'};
    const idleStates = {'waiting', 'missed', 'wrap_time', 'idle'};
    return session.channels
        .where((c) => callChannels.contains(c.channel))
        .any((c) => !idleStates.contains(c.state));
  }

  Future<void> _checkStaleCall() async {
    if (_shutdown || !_callHandler.screenRecordingActive) {
      _staleCallTimer?.cancel();
      _staleCallTimer = null;
      return;
    }
    // Requests made while offline would sit in the queue and go out first on
    // the next connection, ahead of the auth challenge.
    if (!_connection.isConnected) return;
    try {
      final session = await getAgentSession();
      if (!_isCallBusy(session)) {
        _stopRecordingAfterLinkLoss('call_ended_while_disconnected');
      }
    } catch (e) {
      logger.warn('[SOCKET] Stale call check failed: $e');
    }
  }

  // ============================================================================
  // Agent Session API
  // ============================================================================

  /// Fetches and caches basic agent session info.
  /// Persists agentId to storage if available.
  Future<AgentSession> getAgentSession() async {
    final response = await request(SocketActions.agentSession);
    final session = AgentSession.fromJson(response);

    if (session.agentId != 0 && _storage != null) {
      await _storage!.writeAgentId(session.agentId);
    }

    return session;
  }

  // ============================================================================
  // Shutdown
  // ============================================================================

  /// Graceful manual shutdown.
  /// Called when app is closing or user logs out.
  Future<void> disconnect() async {
    logger.info('[SOCKET] MANUAL_DISCONNECT | Disposing manager');
    _shutdown = true;
    _appInitialized = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _networkDebounce?.cancel();
    _networkDebounce = null;
    _recordingGraceTimer?.cancel();
    _recordingGraceTimer = null;
    _permissionRetryTimer?.cancel();
    _permissionRetryTimer = null;
    _pendingPermissionCallId = null;
    onScreenRecordStart = null;
    onScreenRecordStop = null;
    onScreenRecordEnsure = null;
    onAuthRejected = null;
    _clearRecordingTracking();
    _connection.dispose();
    _failPending('Disconnected');
    _callHandler.clear();
    _notificationHandler.dispose();
  }

  // ============================================================================
  // Network Connectivity Listener
  // ============================================================================

  /// Sets up OS-level network change listener.
  ///
  /// On network restored:
  /// - Waits for app initialization to complete
  /// - Triggers full reconnect cycle
  ///
  /// On network lost:
  /// - Relies on WebSocket connection manager to detect
  /// - Cleanup happens via _onDisconnected callback
  ///
  /// Debounces network changes (1s) to avoid thundering herd.
  void _setupConnectivity() {
    Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = !results.contains(ConnectivityResult.none);

      // Cancel previous debounce timer
      _networkDebounce?.cancel();

      // Debounce network state changes (1 second)
      _networkDebounce = Timer(const Duration(seconds: 1), () async {
        if (hasNetwork) {
          logger.info('[NETWORK] RESTORED: $results');

          // Don't reconnect if app still initializing or the user logged out
          if (!_appInitialized || _shutdown) {
            logger.debug('[NETWORK] IGNORE | app still initializing');
            return;
          }

          await _forceReconnect('NETWORK_RESTORED');
        } else {
          logger.warn('[NETWORK] LOST: $results');
          // Note: Actual cleanup happens via _onDisconnected callback
          // from WsConnectionManager when it detects the drop.
        }
      });
    });
  }

  // ============================================================================
  // Token Refresh
  // ============================================================================

  /// Updates authentication token (e.g., after refresh).
  /// Used for next auth cycle.
  void updateToken(String newToken) => _token = newToken;
}
