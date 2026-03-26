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

    // Prioritize parent_id for History grouping, fallback to call_id if parent is missing or invalid.
    final rootCallId = (_isValidUuid(parentId)) ? parentId : callId;

    switch (event) {
      case 'ringing':
      case 'update':
        // if (shouldRecord &&
        if (rootCallId != null &&
            !_activeCalls.any((c) => c['callId'] == rootCallId)) {
          logger.info(
            '[CALL] Starting session: $rootCallId (Attempt: $attemptId)',
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
          logger.info('[CALL] Hangup session: $rootCallId');
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

    if (attemptId == null) return;

    // Track sessions requiring post-call work (reporting/wrap-up).
    if (distribute['has_reporting'] == true &&
        !_postProcessing.any((c) => c['attempt_id'] == attemptId)) {
      logger.info('[CHANNEL] Post-processing started: $attemptId');
      _postProcessing.add({'attempt_id': attemptId});
    }

    // Clear post-processing on transition to idle states.
    if (const ['missed', 'waiting', 'wrap_time'].contains(status)) {
      if (_postProcessing.any((c) => c['attempt_id'] == attemptId)) {
        logger.info('[CHANNEL] Post-processing completed: $attemptId');
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
      logger.info('[STATE] Recording status changed: $_screenRecordingActive');
      onUpdate(_screenRecordingActive, callId);
    }
  }

  void clear() {
    logger.info('[STATE] Force clearing all active sessions');
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;
  }
}
