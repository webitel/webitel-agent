import 'package:webitel_desk_track/core/logger/logger.dart';

/// Coordinates call lifecycle and determines screen recording state.
///
/// State Machine:
/// - IDLE: no active calls, no post-processing
/// - RECORDING: at least one active call (calls.isNotEmpty)
/// - POST_PROCESSING: all calls ended, but post-call processing ongoing
/// - -> STOP when post-processing completes
///
/// Key invariant:
/// Screen recording is active IFF (activeCalls.isNotEmpty || postProcessing.isNotEmpty)
///
/// No "fake" sessions: recordings only START when callId is non-null and
/// permissions are granted. This class only decides "what should be on",
/// WebitelSocket decides "can we actually turn it on".
///
/// Thread safety: All state mutations happen in _evaluateState() callback chain.
/// No race conditions since event handlers are async-sequential in Dart.
class CallHandler {
  // ============================================================================
  // State
  // ============================================================================

  /// Active calls that require immediate screen recording.
  /// Entry format: { callId, attempt_id, segment_id }
  final List<Map<String, dynamic>> _activeCalls = [];

  /// Post-call processing sessions (call ended, but recording continues).
  /// Entry format: { attempt_id, is_pre_registered }
  final List<Map<String, dynamic>> _postProcessing = [];

  /// Current recording state (derived from above lists).
  bool _screenRecordingActive = false;

  // ============================================================================
  // Public Accessors (read-only)
  // ============================================================================

  /// Returns snapshot of currently tracked active calls.
  List<Map<String, dynamic>> get activeCalls => _activeCalls;

  /// Returns snapshot of currently tracked post-processing sessions.
  List<Map<String, dynamic>> get postProcessing => _postProcessing;

  /// True if recording should be active per local state.
  /// This is the "ideal" state; actual recording depends on permissions + callId.
  bool get screenRecordingActive => _screenRecordingActive;

  // ============================================================================
  // UUID Validation
  // ============================================================================

  /// Validates UUID format (v4).
  ///
  /// Valid example: "550e8400-e29b-41d4-a716-446655440000"
  /// Invalid: null, empty, wrong format
  ///
  /// Used to distinguish root call ID from temporary segment/queue IDs.
  ///
  /// Logs warnings if validation fails for debugging purposes.
  bool _isValidUuid(String? uuid) {
    if (uuid == null) {
      logger.warn('[UUID_VALIDATION] UUID is null');
      return false;
    }

    if (uuid.isEmpty) {
      logger.warn('[UUID_VALIDATION] UUID is empty string');
      return false;
    }

    final isValid = RegExp(
      r'^[0-9a-fA-F]{8}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{12}$',
    ).hasMatch(uuid);

    if (!isValid) {
      logger.warn(
        '[UUID_VALIDATION] Invalid UUID format | value="$uuid" | length=${uuid.length}',
      );
    }

    return isValid;
  }

  // ============================================================================
  // Call Event Handling
  // ============================================================================

  /// Processes call events (ringing, active, update, hangup, etc).
  ///
  /// Call flow in Webitel:
  /// 1. Incoming call arrives (ringing)
  /// 2. Answered (active)
  /// 3. May have multiple segments/transfers (update)
  /// 4. Caller hangs up (hangup)
  ///
  /// This handler tracks:
  /// - Root call ID (UUID of original call)
  /// - Reporting requirement (post-call processing needed)
  /// - Screen recording flag (explicit recording request)
  /// - Attempt ID (queue campaign, for post-processing correlation)
  ///
  /// [data] - Raw WebSocket event data
  /// [onUpdate] - Callback when recording state should change
  void handleCallEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    // ========================================================================
    // Extract Call Data
    // ========================================================================

    // Call event usually wraps the call in 'data.items[0]' or 'data.data.call'
    final items = data['data']?['items'] as List?;
    final call =
        items != null && items.isNotEmpty ? items.first : data['data']?['call'];

    if (call == null) {
      logger.warn('[CALL_HANDLER] Call event missing call object');
      _evaluateState(onUpdate, null);
      return;
    }

    // ========================================================================
    // Extract Event Type
    // ========================================================================

    // Event type: 'ringing', 'active', 'hangup', 'update', etc
    final event = call['event'] ?? call['state'];
    if (event == null) {
      logger.warn('[CALL_HANDLER] Call event missing event/state field');
      _evaluateState(onUpdate, null);
      return;
    }

    // ========================================================================
    // Extract Call IDs
    // ========================================================================

    // Segment ID: unique for this call segment (transfers might create new segments)
    final segmentId = call['id']?.toString();

    // Parent ID: points to the original root call (if this is a segment)
    final parentId =
        (call['parent_id'] ?? call['data']?['parent_id'])?.toString();

    // Root call ID: the UUID we correlate with recording
    // Use parent if valid UUID, else use segment
    final rootCallId = _isValidUuid(parentId) ? parentId : segmentId;

    // ========================================================================
    // Extract Task/Queue Information
    // ========================================================================

    // Task object contains campaign/reporting info
    final task = call['task'] as Map<String, dynamic>?;

    // Attempt ID: correlates call with post-processing job
    final attemptId =
        (task?['attempt_id'] ?? call['data']?['queue']?['attempt_id'])
            ?.toString();

    // ========================================================================
    // Extract Flags
    // ========================================================================

    // has_reporting: true if call needs post-call processing
    final hasReporting =
        task?['has_reporting'] == true ||
        call['data']?['queue']?['reporting'] == true ||
        call['data']?['queue']?['reporting'] == 'true';

    // should_record: explicit flag to record screen during call
    final shouldRecord =
        call['data']?['record_screen'] == true ||
        call['variables']?['record_screen'] == 'true';

    // ========================================================================
    // Log for Debugging
    // ========================================================================

    logger.debug(
      '[CALL_EVENT] '
      'event=$event | '
      'root=$rootCallId | '
      'segment=$segmentId | '
      'attempt=$attemptId | '
      'reporting=$hasReporting | '
      'record=$shouldRecord',
    );

    // ========================================================================
    // State Transitions
    // ========================================================================

    switch (event) {
      // ======================================================================
      // Call Starting or Updating
      // ======================================================================
      case 'ringing':
      case 'active':
      case 'update':
        if (shouldRecord && rootCallId != null) {
          // Add to active calls if not already tracking this root ID
          if (!_activeCalls.any((c) => c['callId'] == rootCallId)) {
            logger.info(
              '[CALL] Start tracking | '
              'root=$rootCallId | '
              'segment=$segmentId | '
              'attempt=$attemptId',
            );
            _activeCalls.add({
              'callId': rootCallId,
              'attempt_id': attemptId,
              'segment_id': segmentId,
            });
          }

          // If call has reporting requirement, pre-register post-processing
          if (hasReporting && attemptId != null) {
            final alreadyRegistered = _postProcessing.any(
              (p) => p['attempt_id'] == attemptId,
            );
            if (!alreadyRegistered) {
              _postProcessing.add({
                'attempt_id': attemptId,
                'is_pre_registered':
                    true, // Flag: added during call, not confirmed yet
              });
              logger.info(
                '[CALL] Pre-registered post-processing | '
                'attempt=$attemptId | '
                'root=$rootCallId',
              );
            }
          }
        }
        break;

      // ======================================================================
      // Call Ended
      // ======================================================================
      case 'hangup':
        if (rootCallId != null) {
          logger.info('[CALL] Hangup detected | root=$rootCallId');
          _activeCalls.removeWhere((c) => c['callId'] == rootCallId);
        }
        break;

      default:
        // Ignore unknown events
        break;
    }

    // ========================================================================
    // Re-evaluate Recording State
    // ========================================================================
    _evaluateState(onUpdate, rootCallId);
  }

  // ============================================================================
  // Channel Event Handling
  // ============================================================================

  /// Processes channel status changes (e.g., agent switches to 'processing').
  ///
  /// Channel events correlate to post-call processing:
  /// - 'processing': agent is handling after-call work
  /// - 'missed', 'waiting', 'wrap_time': call is no longer being processed
  ///
  /// Lifecycle:
  /// 1. CALL event arrives with has_reporting=true (pre-register post-processing)
  /// 2. CHANNEL event arrives with status='processing' (confirm active processing)
  /// 3. CHANNEL event arrives with status='missed|waiting|wrap_time' (processing done)
  /// 4. Recording stops once postProcessing list is empty
  ///
  /// [data] - Raw WebSocket event data
  /// [onUpdate] - Callback when recording state should change
  void handleChannelEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    // ========================================================================
    // Extract Channel Data
    // ========================================================================

    final channel = data['data'];
    if (channel == null) {
      logger.warn('[CHANNEL_HANDLER] Channel event missing data');
      _evaluateState(onUpdate, null);
      return;
    }

    // ========================================================================
    // Extract Event Fields
    // ========================================================================

    final status = channel['status'];
    final attemptId =
        (channel['attempt_id'] ?? channel['distribute']?['attempt_id'])
            ?.toString();

    if (attemptId == null) {
      logger.debug('[CHANNEL] Attempt ID missing, skipping');
      _evaluateState(onUpdate, null);
      return;
    }

    // ========================================================================
    // Transition: Pre-Registered -> Confirmed Processing
    // ========================================================================

    if (status == 'processing' || channel['processing'] != null) {
      final index = _postProcessing.indexWhere(
        (p) => p['attempt_id'] == attemptId,
      );

      if (index != -1) {
        // Update pre-registered entry
        _postProcessing[index]['is_pre_registered'] = false;
        logger.debug(
          '[CHANNEL] Confirmed processing state | '
          'attempt=$attemptId | '
          'is_pre_registered=false',
        );
      } else {
        // New post-processing session (channel event arrived before call event)
        _postProcessing.add({
          'attempt_id': attemptId,
          'is_pre_registered': false,
        });
        logger.info(
          '[CHANNEL] Registered post-processing (late arrival) | '
          'attempt=$attemptId',
        );
      }
    }

    // ========================================================================
    // Transition: Processing -> Finished
    // ========================================================================

    if (const ['missed', 'waiting', 'wrap_time'].contains(status)) {
      final existed = _postProcessing.any((p) => p['attempt_id'] == attemptId);

      if (existed) {
        _postProcessing.removeWhere((p) => p['attempt_id'] == attemptId);
        logger.info(
          '[CHANNEL] Post-processing finished | '
          'attempt=$attemptId | '
          'status=$status',
        );
      } else {
        logger.debug(
          '[CHANNEL] Received end status but not tracking: '
          'attempt=$attemptId | '
          'status=$status',
        );
      }
    }

    // ========================================================================
    // Re-evaluate Recording State
    // ========================================================================
    _evaluateState(onUpdate, null);
  }

  // ============================================================================
  // State Evaluation & Transitions
  // ============================================================================

  /// Evaluates whether screen recording should be active.
  ///
  /// Logic:
  /// ```
  /// shouldBeActive = activeCalls.isNotEmpty OR postProcessing.isNotEmpty
  /// ```
  ///
  /// If state changed, calls [onUpdate] callback.
  ///
  /// Callback signature: onUpdate(isActive, callId)
  /// - isActive: new recording state
  /// - callId: root call ID if state=true, else null
  ///
  /// [onUpdate] - Callback for state transitions
  /// [callId] - Optional hint for which call triggered this evaluation
  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    // Determine if recording should be active
    final shouldBeActive =
        _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    // Only fire callback if state actually changed
    if (shouldBeActive != _screenRecordingActive) {
      _screenRecordingActive = shouldBeActive;

      logger.info(
        '[STATE] Recording state transition: '
        'active=$_screenRecordingActive | '
        'calls=${_activeCalls.length} | '
        'post=${_postProcessing.length}',
      );

      onUpdate(_screenRecordingActive, callId);
    }
  }

  // ============================================================================
  // Cleanup
  // ============================================================================

  /// Clears all call state.
  /// Called when:
  /// - WebSocket disconnects (force-stop recording)
  /// - App shutdown
  /// - Out-of-sync detected by watchdog
  void clear() {
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;
    logger.debug('[CALL_HANDLER] All state cleared');
  }
}
