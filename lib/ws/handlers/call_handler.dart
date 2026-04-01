import 'package:webitel_desk_track/core/logger/logger.dart';

/// Coordinates call lifecycle and determines screen recording state.
///
/// State machine:
///   IDLE          → no active calls, no post-processing
///   RECORDING     → at least one active call (activeCalls.isNotEmpty)
///   POST_PROCESS  → all calls ended, post-call processing ongoing
///   IDLE          → post-processing complete (postProcessing.isNotEmpty → empty)
///
/// Key invariant:
///   Recording is active IFF (activeCalls.isNotEmpty || postProcessing.isNotEmpty)
///
/// Root ID resolution strategy:
///   Each call segment carries an optional parent_id pointing to the root call.
///   On ringing/active/update we build a segment→root map so that when a
///   hangup arrives (which often omits parent_id), we can still resolve the
///   correct root and remove it from activeCalls.
///
/// Thread safety:
///   All state mutations happen inside the _evaluateState() callback chain.
///   Dart's single-threaded event loop guarantees no race conditions.
class CallHandler {
  // ============================================================================
  // State
  // ============================================================================

  /// Active calls that require screen recording.
  /// Entry: { callId, attempt_id, segment_id }
  final List<Map<String, dynamic>> _activeCalls = [];

  /// Post-call processing sessions (call ended, recording continues).
  /// Entry: { attempt_id, is_pre_registered }
  final List<Map<String, dynamic>> _postProcessing = [];

  /// Maps every known segmentId → rootCallId.
  ///
  /// Why this exists:
  ///   During ringing/active, the event includes both `id` (segmentId) and
  ///   `parent_id` (rootCallId). We store this mapping so that the hangup
  ///   event — which often arrives without parent_id — can still resolve
  ///   the correct root and cleanly remove it from [_activeCalls].
  ///
  /// Without this map the hangup resolves root=segmentId, which never matches
  ///   what was stored as root=parentId, leaving a ghost entry in _activeCalls
  ///   and preventing the recording from stopping.
  final Map<String, String> _segmentToRoot = {};

  /// Current recording state derived from [_activeCalls] and [_postProcessing].
  bool _screenRecordingActive = false;

  // ============================================================================
  // Public Accessors
  // ============================================================================

  List<Map<String, dynamic>> get activeCalls => List.unmodifiable(_activeCalls);
  List<Map<String, dynamic>> get postProcessing =>
      List.unmodifiable(_postProcessing);
  bool get screenRecordingActive => _screenRecordingActive;

  // ============================================================================
  // UUID Validation
  // ============================================================================

  /// Returns true if [uuid] matches the standard UUID v4 pattern.
  ///
  /// Used to decide whether parent_id is a real root call ID or an absent/
  /// transient value. A segment-only call will have id="uuid" but no parent_id,
  /// while a queued call will have id="agentSegmentUuid" and
  /// parent_id="memberChannelUuid".
  bool _isValidUuid(String? uuid) {
    if (uuid == null || uuid.isEmpty) {
      logger.warn(
        '[UUID] Validation failed | value=${uuid == null ? "null" : "empty"}',
      );
      return false;
    }

    final valid = RegExp(
      r'^[0-9a-fA-F]{8}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{12}$',
    ).hasMatch(uuid);

    if (!valid) {
      logger.warn(
        '[UUID] Invalid format | value="$uuid" | length=${uuid.length}',
      );
    }

    return valid;
  }

  // ============================================================================
  // Call Event Handling
  // ============================================================================

  /// Processes incoming call events and updates recording state accordingly.
  ///
  /// Supported event types:
  ///   ringing / active / update → start or continue tracking the call
  ///   hangup                    → remove call from active tracking
  ///   (anything else)           → ignored, state re-evaluated
  ///
  /// Root ID resolution (see also [_segmentToRoot]):
  ///   1. Extract segmentId from call.id
  ///   2. Extract parentId from call.parent_id (or call.data.parent_id)
  ///   3. rootCallId = parentId if valid UUID, else segmentId
  ///   4. On ringing/active/update: store segmentId→rootCallId in [_segmentToRoot]
  ///   5. On hangup: resolve root via [_segmentToRoot][segmentId] fallback
  ///
  /// [data]     Raw WebSocket event payload.
  /// [onUpdate] Called when recording state transitions: onUpdate(isActive, callId).
  void handleCallEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    // -------------------------------------------------------------------------
    // 1. Extract call object
    // -------------------------------------------------------------------------
    final items = data['data']?['items'] as List?;
    final call =
        (items != null && items.isNotEmpty)
            ? items.first
            : data['data']?['call'];

    if (call == null) {
      logger.warn('[CALL_EVENT] Missing call object in payload — skipping');
      _evaluateState(onUpdate, null);
      return;
    }

    // -------------------------------------------------------------------------
    // 2. Extract event type
    // -------------------------------------------------------------------------
    final event = call['event'] ?? call['state'];
    if (event == null) {
      logger.warn('[CALL_EVENT] Missing event/state field — skipping');
      _evaluateState(onUpdate, null);
      return;
    }

    // -------------------------------------------------------------------------
    // 3. Extract IDs
    // -------------------------------------------------------------------------
    final segmentId = call['id']?.toString();
    final parentIdRaw =
        (call['parent_id'] ?? call['data']?['parent_id'])?.toString();
    final parentIdValid = _isValidUuid(parentIdRaw) ? parentIdRaw : null;

    // Root call ID: prefer the validated parent (original channel that the
    // agent leg was attached to). Fall back to segmentId when no parent exists
    // (e.g. a direct call with no queue).
    final rootCallId = parentIdValid ?? segmentId;

    // -------------------------------------------------------------------------
    // 4. Extract task / queue metadata
    // -------------------------------------------------------------------------
    final task = call['task'] as Map<String, dynamic>?;
    final attemptId =
        (task?['attempt_id'] ?? call['data']?['queue']?['attempt_id'])
            ?.toString();

    final hasReporting =
        task?['has_reporting'] == true ||
        call['data']?['queue']?['reporting'] == true ||
        call['data']?['queue']?['reporting'] == 'true';

    final shouldRecord =
        call['data']?['record_screen'] == true ||
        call['variables']?['record_screen'] == 'true';

    // -------------------------------------------------------------------------
    // 5. Log full context for every event
    // -------------------------------------------------------------------------
    logger.debug(
      '[CALL_EVENT] ──────────────────────────────────────────\n'
      '  event       = $event\n'
      '  segmentId   = $segmentId\n'
      '  parentId    = $parentIdRaw (valid=$parentIdValid)\n'
      '  rootCallId  = $rootCallId\n'
      '  attemptId   = $attemptId\n'
      '  hasReporting= $hasReporting\n'
      '  shouldRecord= $shouldRecord\n'
      '  activeCalls = ${_activeCalls.length} | '
      'postProcessing = ${_postProcessing.length}\n'
      '  segmentMap  = $_segmentToRoot',
    );

    // -------------------------------------------------------------------------
    // 6. State transitions
    // -------------------------------------------------------------------------
    switch (event) {
      // -----------------------------------------------------------------------
      // Call starting or updating
      // -----------------------------------------------------------------------
      case 'ringing':
      case 'active':
      case 'update':
        if (segmentId != null && rootCallId != null) {
          // Always maintain the segment→root map so hangup can resolve correctly
          // even when parent_id is absent from the hangup payload.
          final previousRoot = _segmentToRoot[segmentId];
          if (previousRoot != rootCallId) {
            _segmentToRoot[segmentId] = rootCallId;
            logger.debug(
              '[CALL_EVENT] Segment map updated | '
              'segment=$segmentId → root=$rootCallId'
              '${previousRoot != null ? " (was $previousRoot)" : ""}',
            );
          }
        }

        if (shouldRecord && rootCallId != null) {
          final alreadyTracked = _activeCalls.any(
            (c) => c['callId'] == rootCallId,
          );

          if (!alreadyTracked) {
            _activeCalls.add({
              'callId': rootCallId,
              'attempt_id': attemptId,
              'segment_id': segmentId,
            });
            logger.info(
              '[CALL_EVENT] ▶ Started tracking active call\n'
              '  root=$rootCallId | segment=$segmentId | attempt=$attemptId\n'
              '  activeCalls.length=${_activeCalls.length}',
            );
          } else {
            logger.debug(
              '[CALL_EVENT] Already tracking root=$rootCallId — no duplicate added',
            );
          }

          // Pre-register post-processing so that if the channel "processing"
          // event arrives after hangup, we still hold recording.
          if (hasReporting && attemptId != null) {
            final alreadyRegistered = _postProcessing.any(
              (p) => p['attempt_id'] == attemptId,
            );

            if (!alreadyRegistered) {
              _postProcessing.add({
                'attempt_id': attemptId,
                'is_pre_registered': true,
              });
              logger.info(
                '[CALL_EVENT] ⏳ Pre-registered post-processing\n'
                '  attempt=$attemptId | root=$rootCallId\n'
                '  postProcessing.length=${_postProcessing.length}',
              );
            }
          }
        } else if (!shouldRecord) {
          logger.debug(
            '[CALL_EVENT] record_screen=false for event=$event — '
            'not tracking root=$rootCallId',
          );
        }
        break;

      // -----------------------------------------------------------------------
      // Call ended
      // -----------------------------------------------------------------------
      case 'hangup':
        // Resolve root from segment map first.
        // The hangup payload frequently omits parent_id, so rootCallId derived
        // directly from the payload would equal segmentId — which never matches
        // what was stored under parentId during ringing.
        final resolvedRoot = _segmentToRoot[segmentId] ?? rootCallId;

        logger.info(
          '[CALL_EVENT] ☎ Hangup received\n'
          '  segmentId=$segmentId\n'
          '  rootFromPayload=$rootCallId\n'
          '  rootFromSegmentMap=${_segmentToRoot[segmentId]}\n'
          '  resolvedRoot=$resolvedRoot\n'
          '  activeCalls before=${_activeCalls.map((c) => c["callId"]).toList()}',
        );

        if (resolvedRoot != null) {
          final before = _activeCalls.length;
          _activeCalls.removeWhere((c) => c['callId'] == resolvedRoot);
          final removed = before - _activeCalls.length;

          if (removed > 0) {
            logger.info(
              '[CALL_EVENT] ✔ Removed from activeCalls | root=$resolvedRoot\n'
              '  activeCalls.length=${_activeCalls.length}',
            );
          } else {
            logger.warn(
              '[CALL_EVENT] ✘ Hangup for root=$resolvedRoot but not found in activeCalls\n'
              '  activeCalls=${_activeCalls.map((c) => c["callId"]).toList()}\n'
              '  This may indicate a missed ringing event or a direct call '
              'without record_screen=true — no action needed.',
            );
          }
        }

        // Clean up the segment→root mapping to avoid unbounded growth.
        if (segmentId != null) {
          _segmentToRoot.remove(segmentId);
          logger.debug(
            '[CALL_EVENT] Segment map cleaned | removed segment=$segmentId\n'
            '  segmentMap remaining=${_segmentToRoot.length} entries',
          );
        }
        break;

      default:
        logger.debug('[CALL_EVENT] Unhandled event type="$event" — ignored');
        break;
    }

    _evaluateState(onUpdate, rootCallId);
  }

  // ============================================================================
  // Channel Event Handling
  // ============================================================================

  /// Processes agent channel status changes that relate to post-call work.
  ///
  /// Lifecycle:
  ///   distribute / offering → pre-registration was done by handleCallEvent
  ///   processing            → confirm active post-processing (remove pre-reg flag)
  ///   missed / waiting /
  ///   wrap_time             → post-processing complete, remove from list
  ///
  /// Note on "late arrival" scenario:
  ///   If the channel "processing" event arrives *before* the corresponding
  ///   call event (race condition on reconnect), we still register the session
  ///   so recording starts correctly when the call event arrives.
  ///
  /// [data]     Raw WebSocket event payload.
  /// [onUpdate] Called when recording state transitions.
  void handleChannelEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final channel = data['data'];
    if (channel == null) {
      logger.warn('[CHANNEL_EVENT] Missing data object in payload — skipping');
      _evaluateState(onUpdate, null);
      return;
    }

    final status = channel['status']?.toString();
    final attemptId =
        (channel['attempt_id'] ?? channel['distribute']?['attempt_id'])
            ?.toString();

    logger.debug(
      '[CHANNEL_EVENT] ──────────────────────────────────────────\n'
      '  status    = $status\n'
      '  attemptId = $attemptId\n'
      '  activeCalls      = ${_activeCalls.length}\n'
      '  postProcessing   = ${_postProcessing.map((p) => p["attempt_id"]).toList()}',
    );

    if (attemptId == null) {
      logger.debug(
        '[CHANNEL_EVENT] No attempt_id in payload (status=$status) — skipping',
      );
      _evaluateState(onUpdate, null);
      return;
    }

    // -------------------------------------------------------------------------
    // Transition: pre-registered → confirmed active processing
    // -------------------------------------------------------------------------
    if (status == 'processing' || channel['processing'] != null) {
      final index = _postProcessing.indexWhere(
        (p) => p['attempt_id'] == attemptId,
      );

      if (index != -1) {
        final wasPreRegistered = _postProcessing[index]['is_pre_registered'];
        _postProcessing[index]['is_pre_registered'] = false;
        logger.info(
          '[CHANNEL_EVENT] ✔ Post-processing confirmed\n'
          '  attempt=$attemptId | was_pre_registered=$wasPreRegistered\n'
          '  postProcessing.length=${_postProcessing.length}',
        );
      } else {
        // Processing event arrived before the call event (reconnect race).
        _postProcessing.add({
          'attempt_id': attemptId,
          'is_pre_registered': false,
        });
        logger.info(
          '[CHANNEL_EVENT] ⚡ Late post-processing registration (channel arrived before call)\n'
          '  attempt=$attemptId\n'
          '  postProcessing.length=${_postProcessing.length}',
        );
      }
    }

    // -------------------------------------------------------------------------
    // Transition: active processing → finished
    // -------------------------------------------------------------------------
    if (const {'missed', 'waiting', 'wrap_time'}.contains(status)) {
      final before = _postProcessing.length;
      _postProcessing.removeWhere((p) => p['attempt_id'] == attemptId);
      final removed = before - _postProcessing.length;

      if (removed > 0) {
        logger.info(
          '[CHANNEL_EVENT] ✔ Post-processing finished\n'
          '  attempt=$attemptId | status=$status\n'
          '  postProcessing.length=${_postProcessing.length}\n'
          '  activeCalls.length=${_activeCalls.length}',
        );
      } else {
        logger.debug(
          '[CHANNEL_EVENT] End status received but attempt not tracked\n'
          '  attempt=$attemptId | status=$status\n'
          '  (Normal if call had no reporting or was already cleaned up)',
        );
      }
    }

    _evaluateState(onUpdate, null);
  }

  // ============================================================================
  // State Evaluation
  // ============================================================================

  /// Computes desired recording state and fires [onUpdate] on transitions.
  ///
  /// Logic:
  ///   shouldBeActive = activeCalls.isNotEmpty OR postProcessing.isNotEmpty
  ///
  /// Only fires callback when the state actually changes to avoid
  /// redundant start/stop calls to the recording system.
  ///
  /// [onUpdate] Callback signature: onUpdate(isActive, callId)
  ///   isActive = new recording state
  ///   callId   = root call ID when transitioning to active, else null
  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final shouldBeActive =
        _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    if (shouldBeActive == _screenRecordingActive) {
      logger.debug(
        '[STATE_EVAL] No transition | '
        'recording=$_screenRecordingActive (unchanged)\n'
        '  activeCalls=${_activeCalls.map((c) => c["callId"]).toList()}\n'
        '  postProcessing=${_postProcessing.map((p) => p["attempt_id"]).toList()}',
      );
      return;
    }

    _screenRecordingActive = shouldBeActive;

    logger.info(
      '[STATE_EVAL] ◉ Recording state CHANGED → active=$_screenRecordingActive\n'
      '  callId        = $callId\n'
      '  activeCalls   = ${_activeCalls.length} '
      '(${_activeCalls.map((c) => c["callId"]).toList()})\n'
      '  postProcessing= ${_postProcessing.length} '
      '(${_postProcessing.map((p) => p["attempt_id"]).toList()})\n'
      '  segmentMap    = ${_segmentToRoot.length} entries',
    );

    onUpdate(_screenRecordingActive, _screenRecordingActive ? callId : null);
  }

  // ============================================================================
  // Cleanup
  // ============================================================================

  /// Clears all state.
  ///
  /// Called on:
  ///   - WebSocket disconnect (force-stop recording)
  ///   - App shutdown
  ///   - Watchdog out-of-sync detection
  void clear() {
    final callCount = _activeCalls.length;
    final postCount = _postProcessing.length;
    final mapCount = _segmentToRoot.length;

    _activeCalls.clear();
    _postProcessing.clear();
    _segmentToRoot.clear();
    _screenRecordingActive = false;

    logger.info(
      '[CALL_HANDLER] ✘ All state cleared\n'
      '  removed activeCalls=$callCount | '
      'postProcessing=$postCount | '
      'segmentMap=$mapCount',
    );
  }
}
