import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webitel_desk_track/service/screenshot/sender.dart';

import '../support/fakes.dart';

void main() {
  late Completer<void> serverGate;

  MockClient api() => MockClient((request) async {
    await serverGate.future;
    if (request.url.path.endsWith('/agents')) {
      return http.Response(
        jsonEncode({
          'items': [
            {'screen_control': true},
          ],
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({
        'items': [
          {'value': '5'},
        ],
      }),
      200,
    );
  });

  setUp(() => serverGate = Completer<void>()..complete());

  test('settings enable the capture timer while the service runs', () async {
    await http.runWithClient(() async {
      final service = ScreenshotSenderService(
        baseUrl: 'https://example.com',
        storage: FakeStorage(),
      );
      service.start();
      await service.fetchSettingsForTest();
      expect(service.hasCaptureTimer, isTrue);
      service.stop();
      expect(service.hasCaptureTimer, isFalse);
    }, api);
  });

  test(
    'a settings reply that arrives after stop does not re-arm the timer',
    () async {
      serverGate = Completer<void>();
      await http.runWithClient(() async {
        final service = ScreenshotSenderService(
          baseUrl: 'https://example.com',
          storage: FakeStorage(),
        );
        service.start();
        final inFlight = service.fetchSettingsForTest();
        await Future<void>.delayed(Duration.zero);

        service.stop();
        serverGate.complete();
        await inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.hasCaptureTimer, isFalse);
      }, api);
    },
  );

  test('settings requests carry the token only in a header', () async {
    final urls = <Uri>[];
    await http.runWithClient(
      () async {
        final service = ScreenshotSenderService(
          baseUrl: 'https://example.com',
          storage: FakeStorage(),
        );
        service.start();
        await service.fetchSettingsForTest();
        service.stop();
      },
      () => MockClient((request) async {
        urls.add(request.url);
        expect(request.headers['X-Webitel-Access'], 'test-token-agent');
        return http.Response('{"items":[]}', 200);
      }),
    );
    expect(urls, isNotEmpty);
    expect(urls.any((u) => u.toString().contains('test-token-agent')), isFalse);
  });
}
