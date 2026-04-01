import 'dart:async';
import 'package:webitel_desk_track/core/logger/logger.dart';

/// Handles call lifecycle and screen recording state coordination.
class CallHandler {
  final List<Map<String, dynamic>> _activeCalls = [];
  final List<Map<String, dynamic>> _postProcessing = [];

  bool _screenRecordingActive = false;

  List<Map<String, dynamic>> get activeCalls => _activeCalls;
  List<Map<String, dynamic>> get postProcessing => _postProcessing;
  bool get screenRecordingActive => _screenRecordingActive;

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

  /// Processes raw call events and manages recording state.
  void handleCallEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final items = data['data']?['items'] as List?;
    final call =
        items != null && items.isNotEmpty ? items.first : data['data']?['call'];

    if (call == null) return;

    final event = call['event'] ?? call['state'];
    final segmentId = call['id']?.toString();
    final parentId =
        (call['parent_id'] ?? call['data']?['parent_id'])?.toString();

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

    final rootCallId = _isValidUuid(parentId) ? parentId : segmentId;

    logger.debug(
      '[CALL_EVENT] event=$event | root=$rootCallId | reporting=$hasReporting | attempt=$attemptId',
    );

    switch (event) {
      case 'ringing':
      case 'active':
      case 'update':
        if (shouldRecord && rootCallId != null) {
          if (!_activeCalls.any((c) => c['callId'] == rootCallId)) {
            logger.info('[CALL] Start tracking | root=$rootCallId');
            _activeCalls.add({
              'callId': rootCallId,
              'attempt_id': attemptId,
              'segment_id': segmentId,
            });
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
                '[CHANNEL] Pre-registered post-processing | attempt=$attemptId',
              );
            }
          }
        }
        break;

      case 'hangup':
        if (rootCallId != null) {
          logger.info('[CALL] Hangup detected | root=$rootCallId');
          _activeCalls.removeWhere((c) => c['callId'] == rootCallId);
        }
        break;
    }

    _evaluateState(onUpdate, rootCallId);
  }

  /// Processes channel status changes (e.g., transition to 'processing').
  void handleChannelEvent(
    Map<String, dynamic> data,
    void Function(bool active, String? callId) onUpdate,
  ) {
    final channel = data['data'];
    if (channel == null) return;

    final status = channel['status'];
    final attemptId =
        (channel['attempt_id'] ?? channel['distribute']?['attempt_id'])
            ?.toString();

    if (attemptId == null) {
      _evaluateState(onUpdate, null);
      return;
    }

    if (status == 'processing' || channel['processing'] != null) {
      final index = _postProcessing.indexWhere(
        (p) => p['attempt_id'] == attemptId,
      );
      if (index != -1) {
        _postProcessing[index]['is_pre_registered'] = false;
        logger.debug(
          '[CHANNEL] Confirmed processing state | attempt=$attemptId',
        );
      } else {
        _postProcessing.add({
          'attempt_id': attemptId,
          'is_pre_registered': false,
        });
      }
    }

    if (const ['missed', 'waiting', 'wrap_time'].contains(status)) {
      final bool existed = _postProcessing.any(
        (p) => p['attempt_id'] == attemptId,
      );
      if (existed) {
        _postProcessing.removeWhere((p) => p['attempt_id'] == attemptId);
        logger.info(
          '[CHANNEL] Post-processing finished | attempt=$attemptId | status=$status',
        );
      }
    }

    _evaluateState(onUpdate, null);
  }

  /// Evaluates whether the screen recorder should be running.
  void _evaluateState(
    void Function(bool active, String? callId) onUpdate,
    String? callId,
  ) {
    final shouldBeActive =
        _activeCalls.isNotEmpty || _postProcessing.isNotEmpty;

    if (shouldBeActive != _screenRecordingActive) {
      _screenRecordingActive = shouldBeActive;

      logger.info(
        '[STATE] Recording state changed: active=$_screenRecordingActive '
        '(calls=${_activeCalls.length}, post=${_postProcessing.length})',
      );

      onUpdate(_screenRecordingActive, callId);
    }
  }

  void clear() {
    _activeCalls.clear();
    _postProcessing.clear();
    _screenRecordingActive = false;
    logger.debug('[CallHandler] State cleared');
  }
}
