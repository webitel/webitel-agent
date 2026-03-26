import 'package:webitel_desk_track/core/logger/logger.dart';

class CallHandler {
  final List<Map<String, dynamic>> _activeCalls = [];
  final List<Map<String, dynamic>> _postProcessing = [];
  bool _screenRecordingActive = false;

  // [LOGIC] Public getters to allow state inspection during SYNC
  List<Map<String, dynamic>> get activeCalls => _activeCalls;
  List<Map<String, dynamic>> get postProcessing => _postProcessing;
  bool get screenRecordingActive => _screenRecordingActive;

  void handleCallEvent(
    Map<String, dynamic> data,
    Function(bool active, String? callId) onUpdate,
  ) {
    final call = data['data']?['call'];
    if (call == null) return;

    final event = call['event'];
    final rawCallId = call['id']?.toString();
    final recordScreen = call['data']?['record_screen'] == true;

    switch (event) {
      case 'ringing':
      case 'update':
        // if (!_activeCalls.any((c) => c['callId'] == rawCallId)) {
        if (recordScreen &&
            !_activeCalls.any((c) => c['callId'] == rawCallId)) {
          logger.info('[CALL] STARTING record for CallID: $rawCallId');
          _activeCalls.add({'callId': rawCallId});
        }
        break;
      case 'hangup':
        logger.info('[CALL] HANGUP received for CallID: $rawCallId');
        _activeCalls.removeWhere((c) => c['callId'] == rawCallId);
        break;
    }
    _evaluateState(onUpdate, rawCallId);
  }

  void handleChannelEvent(
    Map<String, dynamic> data,
    Function(bool active, String? callId) onUpdate,
  ) {
    final channel = data['data'];
    if (channel == null) return;

    final status = channel['status'];
    final distribute = channel['distribute'] ?? {};
    final attemptId = distribute['attempt_id'] ?? channel['attempt_id'];

    if (attemptId == null) return;

    if (distribute['has_reporting'] == true &&
        !_postProcessing.any((c) => c['attempt_id'] == attemptId)) {
      logger.info('[CHANNEL] ADDED to Post-Processing: $attemptId');
      _postProcessing.add({'attempt_id': attemptId});
    }

    if (['missed', 'waiting', 'wrap_time'].contains(status)) {
      logger.info(
        '[CHANNEL] REMOVED from Post-Processing: $attemptId | Status: $status',
      );
      _postProcessing.removeWhere((c) => c['attempt_id'] == attemptId);
    }
    _evaluateState(onUpdate, null);
  }

  void _evaluateState(
    Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final shouldRecord = _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;
    if (shouldRecord != _screenRecordingActive) {
      _screenRecordingActive = shouldRecord;
      logger.info('[STATE] Recording toggled to: $_screenRecordingActive');
      onUpdate(_screenRecordingActive, callId);
    }
  }

  void clear() {
    logger.info('[CALL] CLEARING all active sessions and state');
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;
  }
}
