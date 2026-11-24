import 'package:flutter_test/flutter_test.dart';
import 'package:webitel_desk_track/ws/handlers/call_handler.dart';

const _callId = '11111111-2222-4333-8444-555555555555';
const _otherCallId = '66666666-7777-4888-8999-000000000000';

// A manual outbound call event: no task, no queue data.
Map<String, dynamic> _call(
  String event, {
  String id = _callId,
  bool recordScreen = true,
}) => {
  'event': 'call',
  'data': {
    'call': {
      'id': id,
      'event': event,
      'data': {'direction': 'outbound', 'record_screen': recordScreen},
    },
  },
};

Map<String, dynamic> _channel(
  String status, {
  Object attemptId = 734639,
  String agentChannel = 'out_call',
  Map<String, dynamic>? extra,
}) => {
  'event': 'channel',
  'data': {
    'attempt_id': attemptId,
    'channel': agentChannel,
    'status': status,
    ...?extra,
  },
};

Map<String, dynamic> _distribute({
  String agentChannelId = _callId,
  Object? hasReporting = true,
  Object attemptId = 734639,
  String agentChannel = 'out_call',
}) => _channel(
  'distribute',
  attemptId: attemptId,
  agentChannel: agentChannel,
  extra: {
    'distribute': {
      'agent_channel_id': agentChannelId,
      'channel': agentChannel,
      'has_reporting': hasReporting,
    },
  },
);

void main() {
  late CallHandler handler;
  late List<(bool, String?)> updates;

  void onUpdate(bool active, String? callId) => updates.add((active, callId));
  void call(Map<String, dynamic> e) => handler.handleCallEvent(e, onUpdate);
  void channel(Map<String, dynamic> e) =>
      handler.handleChannelEvent(e, onUpdate);

  setUp(() {
    handler = CallHandler();
    updates = [];
  });

  test('outbound recording lasts until post-processing ends even when '
      'hangup comes before processing', () {
    call(_call('ringing', recordScreen: false));
    call(_call('update'));
    channel(_distribute());
    channel(_channel('offering'));
    channel(_channel('bridged'));
    call(_call('active', recordScreen: false));
    call(_call('hangup', recordScreen: false));

    expect(handler.screenRecordingActive, isTrue, reason: 'survives hangup');
    expect(updates, [(true, _callId)]);

    channel(
      _channel(
        'processing',
        extra: {
          'processing': {'sec': 10},
        },
      ),
    );
    expect(updates, [(true, _callId)], reason: 'no restart, no stop');

    channel(_channel('waiting'));
    expect(handler.screenRecordingActive, isFalse);
    expect(updates, [(true, _callId), (false, null)]);
    expect(handler.postProcessing, isEmpty);
    expect(handler.activeCalls, isEmpty);
  });

  test('distribute before the recorded call event still binds', () {
    channel(_distribute());
    expect(updates, isEmpty, reason: 'nothing recorded yet');
    expect(handler.postProcessing, isEmpty);

    call(_call('update'));
    expect(handler.postProcessing.single['attempt_id'], '734639');
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isTrue);

    channel(_channel('waiting'));
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('processing before hangup keeps working', () {
    call(_call('update'));
    channel(_distribute());
    channel(_channel('processing'));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isTrue);
    channel(_channel('waiting'));
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('without reporting the recording stops at hangup', () {
    call(_call('update'));
    channel(_distribute(hasReporting: false));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('has_reporting as the string "true" counts, like in call events', () {
    call(_call('update'));
    channel(_distribute(hasReporting: 'true'));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isTrue);
  });

  test('has_reporting "false" or missing does not keep the recording', () {
    for (final value in ['false', null]) {
      handler.clear();
      call(_call('update'));
      channel(_distribute(hasReporting: value));
      call(_call('hangup', recordScreen: false));
      expect(handler.screenRecordingActive, isFalse, reason: '$value');
    }
  });

  test('a distribute without agent_channel_id is ignored', () {
    call(_call('update'));
    channel(
      _channel(
        'distribute',
        extra: {
          'distribute': {'has_reporting': true},
        },
      ),
    );
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
  });

  test('a call that is not recorded never starts recording via '
      'distribute', () {
    call(_call('update', recordScreen: false));
    channel(_distribute());
    expect(handler.postProcessing, isEmpty);
    expect(handler.screenRecordingActive, isFalse);
    expect(updates, isEmpty);
  });

  test('distribute for another channel does not keep this recording', () {
    call(_call('update'));
    channel(_distribute(agentChannelId: _otherCallId));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('a duplicate distribute registers post-processing once', () {
    call(_call('update'));
    channel(_distribute());
    channel(_distribute());
    call(_call('update'));
    expect(handler.postProcessing, hasLength(1));
  });

  test('an unanswered call ends on missed without processing', () {
    call(_call('update'));
    channel(_distribute());
    call(_call('hangup', recordScreen: false));
    channel(_channel('missed'));
    expect(handler.screenRecordingActive, isFalse);
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('the end of an attempt cleans up its pending binding', () {
    channel(_distribute());
    channel(_channel('waiting'));
    call(_call('update'));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
  });

  test('hangup of an unrecorded call cleans up its pending binding', () {
    channel(_distribute());
    call(_call('hangup', recordScreen: false));
    call(_call('update'));
    expect(handler.postProcessing, isEmpty);
  });

  test('inbound queue call: task and distribute register post-processing '
      'once', () {
    const member = '99999999-8888-4777-8666-555555555555';
    Map<String, dynamic> inbound(String event) => {
      'event': 'call',
      'data': {
        'call': {
          'id': _callId,
          'parent_id': member,
          'event': event,
          'task': {'attempt_id': 77, 'has_reporting': true},
          'data': {'record_screen': true},
        },
      },
    };

    channel(_distribute(attemptId: 77, agentChannel: 'call'));
    call(inbound('ringing'));
    call(inbound('active'));
    expect(handler.postProcessing, hasLength(1));

    call(inbound('hangup'));
    expect(handler.screenRecordingActive, isTrue);
    channel(_channel('processing', attemptId: 77, agentChannel: 'call'));
    channel(_channel('waiting', attemptId: 77, agentChannel: 'call'));
    expect(updates, [(true, member), (false, null)]);
  });

  test('waiting for the bound attempt ends a call whose hangup was lost', () {
    call(_call('update'));
    channel(_distribute());
    channel(_channel('waiting'));
    expect(handler.activeCalls, isEmpty);
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('a malformed distribute payload is ignored without throwing', () {
    call(_call('update'));
    channel(_channel('distribute', extra: {'distribute': 'oops'}));
    channel({'event': 'channel', 'data': 'oops'});
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
  });

  test('a distribute without any attempt id is ignored without throwing', () {
    call(_call('update'));
    channel({
      'event': 'channel',
      'data': {'status': 'distribute', 'distribute': 'oops'},
    });
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
  });

  test('processing during a recorded call without distribute still keeps '
      'the recording until it ends', () {
    call(_call('update'));
    channel(_channel('processing'));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isTrue);
    channel(_channel('waiting'));
    expect(updates, [(true, _callId), (false, null)]);
  });

  test('clear drops pending bindings', () {
    channel(_distribute());
    handler.clear();
    call(_call('update'));
    call(_call('hangup', recordScreen: false));
    expect(handler.screenRecordingActive, isFalse);
  });
}
