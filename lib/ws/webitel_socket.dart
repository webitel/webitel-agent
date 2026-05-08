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

/// WebSocket connection manager for Webitel desktop app.
///
/// Responsibilities:
/// - Manages WebSocket lifecycle (connect, authenticate, disconnect)
/// - Routes incoming events to appropriate handlers
/// - Maintains request-reply correlation via sequence numbers
/// - Implements watchdog for detecting out-of-sync recording state
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
  bool _isAuthenticating = false;

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
  // Watchdog Timer (Sync Detection)
  // ============================================================================

  /// Periodic timer that checks server state to detect out-of-sync sessions.
  /// Kills ghost recordings if no active calls exist on server.
  Timer? _watchdogTimer;
  static const _watchdogInterval = Duration(seconds: 30);

  // ============================================================================
  // Streams & Callbacks
  // ============================================================================

  /// Broadcasts agent status changes (e.g., 'online', 'offline', 'busy').
  final _agentStatusController = StreamController<String>.broadcast();
  Stream<String> get agentStatusStream => _agentStatusController.stream;

  /// External callbacks for recording lifecycle events.
  /// Called when recording should START (valid callId + permissions granted).
  void Function(Map<String, dynamic> body)? onScreenRecordStart;

  /// Called when recording should STOP (all calls/post-processing ended).
  void Function(Map<String, dynamic> body)? onScreenRecordStop;

  // ============================================================================
  // Lifecycle Flags
  // ============================================================================

  /// Prevents multiple reconnect attempts in parallel.
  bool _isReconnecting = false;

  /// Guards against network debounce race conditions.
  Timer? _networkDebounce;

  /// Prevents reconnect actions before app initialization is complete.
  bool _appInitialized = false;

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
        (body) => onScreenRecordStart?.call(body);
    _notificationHandler.onScreenRecordStop =
        (body) => onScreenRecordStop?.call(body);
  }

  // ============================================================================
  // Connection Lifecycle
  // ============================================================================

  /// Initiates the physical WebSocket connection to the server.
  /// No-op if already connected.
  Future<void> connect() async {
    if (_connection.isConnected) return;
    if (config == null) {
      logger.error('[SOCKET] Connection aborted: Config missing');
      return;
    }
    await _connection.connect(config!.url);
  }

  /// Full reconnection cycle: connect + authenticate + sync + refresh.
  /// Used for both initial connection and network recovery.
  ///
  /// [source] - Reason for reconnect (e.g., 'NETWORK_RESTORED', 'RETRY_TIMER')
  Future<void> _performFullReconnect(String source) async {
    logger.info('[SOCKET] RECONNECT_START | Source: $source');

    try {
      await connect();
      await authenticate();

      // Immediately check if local recording state matches server state.
      // Catches cases where server dropped the call but client didn't notice.
      await _checkSyncStatus();

      // Fetch minimal agent info to confirm session is valid.
      // Does NOT resync active calls (CallHandler handles that).
      await getAgentSession();

      logger.info('[SOCKET] RECONNECT_SUCCESS');
    } catch (e) {
      logger.error('[SOCKET] RECONNECT_FAILED: $e');
    }
  }

  /// Authenticates with the server by sending auth challenge.
  ///
  /// Closes the auth gate (blocks all requests) until server sends 'hello'.
  /// Timeout: 7 seconds from challenge to hello. If exceeded, completes anyway
  /// to prevent deadlock (assumes auth is OK, worst case it fails on next request).
  ///
  /// Starts watchdog timer on success.
  Future<void> authenticate() async {
    if (_isAuthenticating) return;
    _isAuthenticating = true;

    try {
      // Wait for transport ready with short timeout.
      await _connection.ready.timeout(const Duration(seconds: 5));

      if (!_connection.isConnected) {
        logger.warn('[SOCKET] Aborting auth: connection not active');
        return;
      }

      logger.info('[SOCKET] AUTH_START (Gate Closed)');
      _authGate = Completer<void>();

      // Send authentication challenge.
      await _sendRawRequest(SocketActions.authenticationChallenge, {
        'token': _token,
      });

      // Wait for server 'hello' response. Timeout prevents indefinite blocking.
      await _authGate!.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () {
          logger.warn('[SOCKET] Auth gate timeout, proceeding...');
          if (_authGate?.isCompleted == false) _authGate?.complete();
        },
      );

      logger.info('[SOCKET] AUTH_COMPLETED');
      _startWatchdog();
    } catch (e, st) {
      logger.error('[SOCKET] AUTH_FAILED: $e', e, st);
    } finally {
      _isAuthenticating = false;
    }
  }

  // ============================================================================
  // Watchdog (Out-of-Sync Detection)
  // ============================================================================

  /// Starts periodic background sync check (every 30 seconds).
  /// Ensures local recording state matches actual server-side agent session.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      _watchdogInterval,
      (_) => _checkSyncStatus(),
    );
    logger.debug('[WATCHDOG] Periodic sync timer started (30s)');
  }

  /// Stops the periodic sync timer.
  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    logger.debug('[WATCHDOG] Periodic sync timer stopped');
  }

  /// Fetches active calls from server and compares to local state.
  /// If server has no calls but client thinks recording is active -> kills it.
  ///
  /// This handles the race condition:
  /// 1. Server drops call
  /// 2. Network glitch delays the hangup event
  /// 3. Client still thinks recording is running
  /// 4. Watchdog detects mismatch -> forces stop
  ///
  /// Errors are logged but never thrown (don't crash watchdog loop).
  Future<void> _checkSyncStatus() async {
    // Only check if authenticated and connected.
    if (!_connection.isConnected ||
        _authGate == null ||
        !_authGate!.isCompleted) {
      return;
    }

    try {
      // Request active calls for current user.
      final response = await request(SocketActions.callByUser);

      // Parse response. Expected format: { items: [...calls...] }
      final List? activeCalls = response['items'] as List?;
      final bool hasActiveCalls = activeCalls != null && activeCalls.isNotEmpty;

      // Detect out-of-sync state.
      if (!hasActiveCalls && _callHandler.screenRecordingActive) {
        logger.warn(
          '[WATCHDOG] Out-of-sync detected! No active calls via ${SocketActions.callByUser} '
          'but recording marked active. Terminating orphaned session.',
        );

        // Force recording stop and clear internal state.
        _onRecordingStateChanged(false, null);
        _callHandler.clear();
      }
    } catch (e) {
      // Silence watchdog errors to avoid log spam during network issues.
      logger.error('[WATCHDOG] Sync check failed: $e');
    }
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
      // Guard 1: Valid call context required
      if (callId == null) {
        logger.warn(
          '[SOCKET] RECORD_START skipped: missing callId '
          '(likely post-processing only, call will be recorded after hangup)',
        );
        return;
      }

      // Guard 2: Screenshot permission required
      if (!(_screenshotService?.isControlEnabled ?? false)) {
        logger.warn(
          '[SOCKET] RECORD_START blocked: permission denied (callId=$callId)',
        );
        return;
      }

      logger.info('[SOCKET] RECORD_START | callId=$callId');
      onScreenRecordStart?.call({'root_id': callId, 'source': 'call_event'});
    } else {
      // STOP: No guards, always fire
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
    if (_isReconnecting) return;
    _isReconnecting = true;

    try {
      // Allow any in-flight auth to complete.
      while (_isAuthenticating) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

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
      if (e is SocketError && retryCount < 2) {
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
  /// - Stop watchdog timer
  /// - Force-stop any active recording (prevents ghost sessions)
  /// - Fail all pending requests
  /// - Clear state
  /// - Schedule retry with exponential backoff
  ///
  /// This is the most critical method for preventing ghost recordings.
  void _onDisconnected() {
    _stopWatchdog();
    logger.warn('[SOCKET] DISCONNECT_DETECTED | Cleaning up state...');

    // ========================================================================
    // Critical: Kill any active recording due to link loss.
    // We cannot trust local state if network is down.
    // ========================================================================
    if (_callHandler.screenRecordingActive) {
      logger.warn(
        '[SOCKET] DISCONNECT_CLEANUP: Stopping active recording due to network loss',
      );
      onScreenRecordStop?.call({'reason': 'network_loss_cleanup'});
      _callHandler.clear();
    }

    // ========================================================================
    // Clean up authentication state
    // ========================================================================
    _isAuthenticating = false;

    if (_authGate != null && !_authGate!.isCompleted) {
      _authGate!.completeError(
        SocketError(detail: 'Disconnected', code: 0, id: '', status: 'FAIL'),
      );
    }
    _authGate = null;

    // ========================================================================
    // Clean up pending requests (fail all)
    // ========================================================================
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

    // ========================================================================
    // Schedule retry with exponential backoff
    // ========================================================================
    final retryDelay = _connection.getNextRetryDelay();
    logger.info('[SOCKET] RETRY_TIMER | Scheduled in ${retryDelay.inSeconds}s');

    Future.delayed(retryDelay, () async {
      if (!_connection.isConnected) {
        await _performFullReconnect('RETRY_TIMER');
      }
    });
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
    _stopWatchdog();
    _connection.dispose();
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

          // Don't reconnect if app still initializing
          if (!_appInitialized) {
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
