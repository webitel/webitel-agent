import 'package:webitel_desk_track/core/logger/logger.dart';

/// Handles call lifecycle and screen recording state.
///
/// Core principles:
/// - Recording is STARTED only by a valid call event with `record_screen = true`.
/// - Channel (`distribute`) events can EXTEND the session (post-processing),
///   but must NEVER start a new recording session if no call is present.
/// - Recording remains active while:
///   activeCalls.isNotEmpty OR postProcessing.isNotEmpty
class CallHandler {
  final List<Map<String, dynamic>> _activeCalls = [];
  final List<Map<String, dynamic>> _postProcessing = [];

  bool _screenRecordingActive = false;

  List<Map<String, dynamic>> get activeCalls => _activeCalls;
  List<Map<String, dynamic>> get postProcessing => _postProcessing;
  bool get screenRecordingActive => _screenRecordingActive;

  /// Validates UUID format (8-4-4-4-12 hex pattern).
  bool _isValidUuid(String? uuid) {
    if (uuid == null) return false;
    return RegExp(
      r'^[0-9a-fA-F]{8}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{12}$',
    ).hasMatch(uuid);
  }

  /// Handles call-related WebSocket events.
  ///
  /// This is the PRIMARY place where a recording session can START.
  void handleCallEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final call = data['data']?['call'];
    if (call == null) return;

    final event = call['event'];
    final segmentId = call['id']?.toString();

    // Support both flat and nested parent_id
    final parentId =
        (call['parent_id'] ?? call['data']?['parent_id'])?.toString();

    final attemptId = call['data']?['queue']?['attempt_id']?.toString();
    final shouldRecord = call['data']?['record_screen'] == true;

    // Resolve root call ID (used as session identifier)
    final rootCallId = _isValidUuid(parentId) ? parentId : segmentId;

    logger.debug(
      '[CALL_EVENT] event=$event | segment=$segmentId | root=$rootCallId | record=$shouldRecord',
    );

    switch (event) {
      case 'ringing':
      case 'active':
      case 'update':
        // [GUARD] Start session ONLY if:
        // - recording is explicitly allowed by the platform
        // - we have a valid rootCallId
        // - session is not already being tracked
        if (shouldRecord &&
            rootCallId != null &&
            !_activeCalls.any((c) => c['callId'] == rootCallId)) {
          logger.info(
            '[CALL] Start session | root=$rootCallId | attempt=$attemptId',
          );

          _activeCalls.add({
            'callId': rootCallId,
            'attempt_id': attemptId,
            'segment_id': segmentId,
          });
        }
        break;

      case 'hangup':
        if (rootCallId != null) {
          logger.info('[CALL] Hangup detected | root=$rootCallId');

          // Remove both root and segment references from active list
          _activeCalls.removeWhere(
            (c) => c['callId'] == rootCallId || c['segment_id'] == segmentId,
          );
        }
        break;

      default:
        logger.debug('[CALL_EVENT] Ignored event: $event');
    }

    _evaluateState(onUpdate, rootCallId);
  }

  /// Handles channel (agent state) events.
  ///
  /// These events manage the post-processing lifecycle (reporting/wrap-up).
  void handleChannelEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final channel = data['data'];
    if (channel == null) return;

    final status = channel['status'];
    final distribute = channel['distribute'] ?? {};

    final attemptId =
        (distribute['attempt_id'] ?? channel['attempt_id'])?.toString();

    if (attemptId == null) {
      _evaluateState(onUpdate, null);
      return;
    }

    final hasReporting = distribute['has_reporting'] == true;

    // [LOGIC] Add to post-processing queue to extend the session AFTER the call ends
    if (hasReporting) {
      final exists = _postProcessing.any((c) => c['attempt_id'] == attemptId);

      if (!exists) {
        _postProcessing.add({
          'attempt_id': attemptId,
          'timestamp': channel['timestamp'],
        });

        logger.info(
          '[CHANNEL] Post-processing extension started | attempt=$attemptId',
        );
      }
    }

    // [LOGIC] Remove from post-processing when agent returns to idle/waiting states
    if (const ['missed', 'waiting', 'wrap_time'].contains(status)) {
      final existed = _postProcessing.any((c) => c['attempt_id'] == attemptId);

      if (existed) {
        _postProcessing.removeWhere((c) => c['attempt_id'] == attemptId);

        logger.info(
          '[CHANNEL] Post-processing finished | attempt=$attemptId | status=$status',
        );
      }
    }

    _evaluateState(onUpdate, null);
  }

  /// Evaluates global recording state based on calls and post-processing.
  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final hasActiveCalls = _activeCalls.isNotEmpty;
    final hasPostProcessing = _postProcessing.isNotEmpty;

    // [CRITICAL FIX] Session is active if there is a call OR post-processing.
    // This prevents 'hangup' from killing the recording while agent is still reporting.
    final shouldBeActive = hasActiveCalls || hasPostProcessing;

    if (shouldBeActive != _screenRecordingActive) {
      // [GUARD] Prevention of "Ghost Starts":
      // Do not transition from FALSE to TRUE if there are NO active calls.
      // This ensures post-processing events alone cannot trigger a new recording.
      if (shouldBeActive && !hasActiveCalls && !_screenRecordingActive) {
        logger.warn(
          '[STATE] Blocked recording start: post-processing exists but no active call',
        );
        return;
      }

      _screenRecordingActive = shouldBeActive;

      logger.info(
        '[STATE] Recording state changed: active=$_screenRecordingActive '
        '(calls=${_activeCalls.length}, post=${_postProcessing.length})',
      );

      onUpdate(_screenRecordingActive, callId);
    }
  }

  /// Clears all internal state (e.g., on disconnect or logout).
  void clear() {
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;

    logger.debug('[CallHandler] State cleared');
  }
}
