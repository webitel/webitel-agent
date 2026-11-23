import 'package:flutter_test/flutter_test.dart';
import 'package:webitel_desk_track/service/screenshot/sender.dart';
import 'package:webitel_desk_track/ws/handlers/call_handler.dart';
import 'package:webitel_desk_track/ws/handlers/notification_handler.dart';

import '../support/fakes.dart';

class _Screenshots extends ScreenshotSenderService {
  String? result;
  _Screenshots(this.result)
    : super(baseUrl: 'https://example.com', storage: FakeStorage());

  @override
  Future<String?> capture() async => result;
}

void main() {
  late List<Map<String, dynamic>> acks;
  late _Screenshots screenshots;
  late NotificationHandler handler;

  setUp(() {
    acks = [];
    screenshots = _Screenshots(null);
    handler = NotificationHandler(
      screenshotService: screenshots,
      callHandler: CallHandler(),
      requestExecutor: (action, [data]) async {
        acks.add({'action': action, ...?data});
        return {};
      },
    );
  });

  Map<String, dynamic> notification(String action) => {
    'data': {
      'notification': {
        'action': action,
        'body': {'ack_id': 'ack-1'},
      },
    },
  };

  test(
    'a recording that fails to start is acknowledged with an error',
    () async {
      handler.onScreenRecordStart = (_) async => false;
      await handler.handle(notification('ss_record_start'));
      expect(acks.single['error'], 'Screen recording failed to start');
    },
  );

  test('a started recording is acknowledged without an error', () async {
    handler.onScreenRecordStart = (_) async => true;
    await handler.handle(notification('ss_record_start'));
    expect(acks.single.containsKey('error'), isFalse);
  });

  test('a failed screenshot is acknowledged with its reason', () async {
    screenshots.result = 'Screenshot upload failed with status 500';
    await handler.handle(notification('screenshot'));
    expect(acks.single['error'], 'Screenshot upload failed with status 500');
  });

  test('a successful screenshot is acknowledged without an error', () async {
    await handler.handle(notification('screenshot'));
    expect(acks.single.containsKey('error'), isFalse);
  });
}
