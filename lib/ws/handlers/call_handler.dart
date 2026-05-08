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
    // agent leg was attached to). Fall back to segmentId when no parent exists.
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
        // FIX: Use segment map but also handle direct matches.
        final resolvedRoot = _segmentToRoot[segmentId] ?? rootCallId;

        logger.info(
          '[CALL_EVENT] ☎ Hangup received\n'
          '  segmentId=$segmentId\n'
          '  rootFromPayload=$rootCallId\n'
          '  rootFromSegmentMap=${_segmentToRoot[segmentId]}\n'
          '  resolvedRoot=$resolvedRoot\n'
          '  activeCalls before=${_activeCalls.map((c) => c["callId"]).toList()}',
        );

        if (resolvedRoot != null || segmentId != null) {
          final before = _activeCalls.length;

          // FIX: Remove call using both root ID and segment ID as a fallback
          // because hangup often arrives with only segmentId.
          _activeCalls.removeWhere(
            (c) => c['callId'] == resolvedRoot || c['segment_id'] == segmentId,
          );

          final removed = before - _activeCalls.length;

          if (removed > 0) {
            logger.info(
              '[CALL_EVENT] ✔ Removed from activeCalls | root=$resolvedRoot\n'
              '  activeCalls.length=${_activeCalls.length}',
            );
          } else {
            logger.warn(
              '[CALL_EVENT] ✘ Hangup for root=$resolvedRoot but not found in activeCalls\n'
              '  activeCalls=${_activeCalls.map((c) => c["callId"]).toList()}',
            );
          }
        }

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
        _postProcessing[index]['is_pre_registered'] = false;
        logger.info(
          '[CHANNEL_EVENT] ✔ Post-processing confirmed | attempt=$attemptId',
        );
      } else {
        _postProcessing.add({
          'attempt_id': attemptId,
          'is_pre_registered': false,
        });
        logger.info(
          '[CHANNEL_EVENT] ⚡ Late post-processing registration | attempt=$attemptId',
        );
      }
    }

    // -------------------------------------------------------------------------
    // Transition: active processing → finished
    // -------------------------------------------------------------------------
    if (const {'missed', 'waiting', 'wrap_time'}.contains(status)) {
      final beforePost = _postProcessing.length;
      _postProcessing.removeWhere((p) => p['attempt_id'] == attemptId);
      final removedPost = beforePost - _postProcessing.length;

      // FIX: If agent returns to 'waiting', force clear any active call
      // associated with this attemptId. This handles cases where 'hangup'
      // failed to clean up activeCalls due to ID mismatch.
      final beforeActive = _activeCalls.length;
      _activeCalls.removeWhere((c) => c['attempt_id'] == attemptId);
      final removedActive = beforeActive - _activeCalls.length;

      if (removedPost > 0 || removedActive > 0) {
        logger.info(
          '[CHANNEL_EVENT] ✔ Cleanup finished for attempt=$attemptId\n'
          '  status=$status | removedPost=$removedPost | removedActive=$removedActive\n'
          '  activeCalls.length=${_activeCalls.length}',
        );
      }
    }

    _evaluateState(onUpdate, null);
  }

  // ============================================================================
  // State Evaluation
  // ============================================================================

  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final shouldBeActive =
        _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    if (shouldBeActive == _screenRecordingActive) {
      logger.debug(
        '[STATE_EVAL] No transition | recording=$_screenRecordingActive (unchanged)\n'
        '  activeCalls=${_activeCalls.map((c) => c["callId"]).toList()}\n'
        '  postProcessing=${_postProcessing.map((p) => p["attempt_id"]).toList()}',
      );
      return;
    }

    _screenRecordingActive = shouldBeActive;

    logger.info(
      '[STATE_EVAL] ◉ Recording state CHANGED → active=$_screenRecordingActive\n'
      '  callId        = $callId\n'
      '  activeCalls   = ${_activeCalls.length}\n'
      '  postProcessing= ${_postProcessing.length}',
    );

    onUpdate(_screenRecordingActive, _screenRecordingActive ? callId : null);
  }

  // ============================================================================
  // Cleanup
  // ============================================================================

  void clear() {
    _activeCalls.clear();
    _postProcessing.clear();
    _segmentToRoot.clear();
    _screenRecordingActive = false;

    logger.info('[CALL_HANDLER] ✘ All state cleared');
  }
}
