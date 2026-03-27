import 'package:webitel_desk_track/core/logger/logger.dart';

class CallHandler {
  final List<Map<String, dynamic>> _activeCalls = [];
  final List<Map<String, dynamic>> _postProcessing = [];
  bool _screenRecordingActive = false;

  List<Map<String, dynamic>> get activeCalls => _activeCalls;
  List<Map<String, dynamic>> get postProcessing => _postProcessing;
  bool get screenRecordingActive => _screenRecordingActive;

  /// Validates UUID format according to RFC 4122 (8-4-4-4-12 hex).
  /// This ensures compatibility with backend storage and History filters.
  bool _isValidUuid(String? uuid) {
    if (uuid == null) return false;
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(uuid);
  }

  void handleCallEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final call = data['data']?['call'];
    if (call == null) return;

    final event = call['event'];
    final callId = call['id']?.toString();
    final parentId = call['data']?['parent_id']?.toString();
    final attemptId = call['data']?['queue']?['attempt_id']?.toString();
    final shouldRecord = call['data']?['record_screen'] == true;

    // Logic for Root ID resolution
    final bool parentIsValid = _isValidUuid(parentId);
    final rootCallId = parentIsValid ? parentId : callId;

    // Detailed descriptive logging for traceability
    logger.debug(
      '[CALL_EVENT] Incoming: $event | call_id: $callId | parent_id: $parentId (valid: $parentIsValid) | record_screen: $shouldRecord',
    );

    switch (event) {
      case 'ringing':
      case 'update':
        // if (shouldRecord &&
        if (rootCallId != null &&
            !_activeCalls.any((c) => c['callId'] == rootCallId)) {
          logger.info(
            '[CALL] Starting session. Resolved Root ID: $rootCallId '
            '${parentIsValid ? "(from parent_id)" : "(from call_id)"} | Attempt: $attemptId',
          );

          _activeCalls.add({
            'callId': rootCallId,
            'attempt_id': attemptId,
            'segment_id': callId,
          });
        }
        break;

      case 'hangup':
        if (rootCallId != null) {
          logger.info(
            '[CALL] Hangup received. Cleaning up session: $rootCallId',
          );
          _activeCalls.removeWhere((c) => c['callId'] == rootCallId);
        }
        break;
    }

    _evaluateState(onUpdate, rootCallId);
  }

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

    logger.debug('[CHANNEL_EVENT] status: $status | attempt_id: $attemptId');

    if (attemptId == null) return;

    // Track sessions requiring post-call work (reporting/wrap-up).
    if (distribute['has_reporting'] == true &&
        !_postProcessing.any((c) => c['attempt_id'] == attemptId)) {
      logger.info(
        '[CHANNEL] Post-processing started for attempt: $attemptId (reporting required)',
      );
      _postProcessing.add({'attempt_id': attemptId});
    }

    // Clear post-processing on transition to idle states.
    if (const ['missed', 'waiting', 'wrap_time'].contains(status)) {
      if (_postProcessing.any((c) => c['attempt_id'] == attemptId)) {
        logger.info(
          '[CHANNEL] Post-processing completed. Agent moved to $status state for attempt: $attemptId',
        );
        _postProcessing.removeWhere((c) => c['attempt_id'] == attemptId);
      }
    }

    _evaluateState(onUpdate, null);
  }

  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final shouldBeActive =
        _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    if (shouldBeActive != _screenRecordingActive) {
      _screenRecordingActive = shouldBeActive;
      logger.info(
        '[STATE] Recording logic updated: active=$_screenRecordingActive '
        '(ActiveCalls: ${_activeCalls.length}, PostProc: ${_postProcessing.length})',
      );
      onUpdate(_screenRecordingActive, callId);
    }
  }

  void clear() {
    logger.warn(
      '[STATE] Force clearing all session tracking arrays (ActiveCalls & PostProcessing)',
    );
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;
  }
}
