import 'package:webitel_desk_track/core/logger/logger.dart';

class CallHandler {
  final List<Map<String, dynamic>> _activeCalls = [];
  final List<Map<String, dynamic>> _postProcessing = [];
  bool _screenRecordingActive = false;

  List<Map<String, dynamic>> get activeCalls => _activeCalls;
  List<Map<String, dynamic>> get postProcessing => _postProcessing;
  bool get screenRecordingActive => _screenRecordingActive;

  /// Validates UUID format according to RFC 4122.
  bool _isValidUuid(String? uuid) {
    if (uuid == null) return false;
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(uuid);
  }

  /// Processes call-related events from the WebSocket.
  void handleCallEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final call = data['data']?['call'];
    if (call == null) return;

    final event = call['event'];
    final callId = call['id']?.toString();

    // Support both nested and flat parent_id structures from Webitel events
    final parentId =
        (call['parent_id'] ?? call['data']?['parent_id'])?.toString();
    final attemptId = call['data']?['queue']?['attempt_id']?.toString();
    final shouldRecord = call['data']?['record_screen'] == true;

    // Resolve Root ID: Use parent_id if valid, otherwise fallback to callId
    final bool parentIsValid = _isValidUuid(parentId);
    final rootCallId = parentIsValid ? parentId : callId;

    logger.debug(
      '[CALL_EVENT] Incoming: $event | call_id: $callId | root_id: $rootCallId | record: $shouldRecord',
    );

    switch (event) {
      case 'ringing':
      case 'active':
      case 'update':
        if (rootCallId != null &&
            !_activeCalls.any((c) => c['callId'] == rootCallId)) {
          logger.info(
            '[CALL] Starting session. Root: $rootCallId | Attempt: $attemptId',
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
          logger.info('[CALL] Hangup: Cleaning up session $rootCallId');
          // Cleanup using both IDs to ensure no zombie sessions remain
          _activeCalls.removeWhere(
            (c) => c['callId'] == rootCallId || c['segment_id'] == callId,
          );
        }
        break;
    }

    _evaluateState(onUpdate, rootCallId);
  }

  /// Processes agent channel status events (Wrap-up, Idle, etc.).
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

    // Handle Wrap-up/Reporting state tracking
    if (distribute['has_reporting'] == true &&
        !_postProcessing.any((c) => c['attempt_id'] == attemptId)) {
      _postProcessing.add({'attempt_id': attemptId});
    }

    // Clear post-processing when agent returns to idle states
    if (const ['missed', 'waiting', 'wrap_time'].contains(status)) {
      _postProcessing.removeWhere((c) => c['attempt_id'] == attemptId);
    }

    _evaluateState(onUpdate, null);
  }

  /// Evaluates if screen recording should be active based on current calls and post-processing.
  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final shouldBeActive =
        _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    if (shouldBeActive != _screenRecordingActive) {
      _screenRecordingActive = shouldBeActive;
      logger.info(
        '[STATE] Update: active=$_screenRecordingActive (Calls: ${_activeCalls.length}, Post: ${_postProcessing.length})',
      );
      onUpdate(_screenRecordingActive, callId);
    }
  }

  /// Full reset of the handler state.
  void clear() {
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;
  }
}
