import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webitel_desk_track/service/screenshot/sender.dart';
import 'package:webitel_desk_track/ws/core/config.dart';
import 'package:webitel_desk_track/ws/core/error.dart';
import 'package:webitel_desk_track/ws/webitel_socket.dart';

import '../support/fakes.dart';

class _FakeWebitel {
  late final HttpServer http;
  final sockets = <WebSocket>[];
  bool rejectAuth = false;
  String callChannelState = 'waiting';
  int authAttempts = 0;

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) => _onRequest(socket, jsonDecode(raw as String)));
    });
  }

  String get url => 'ws://127.0.0.1:${http.port}';

  void _onRequest(WebSocket socket, Map<String, dynamic> req) {
    final seq = req['seq'];
    switch (req['action']) {
      case 'authentication_challenge':
        authAttempts++;
        if (rejectAuth) {
          socket.add(
            jsonEncode({
              'seq_reply': seq,
              'status': 'FAIL',
              'error': {'id': 'auth', 'status': 'Unauthorized', 'code': 401},
            }),
          );
        } else {
          socket.add(jsonEncode({'seq_reply': seq, 'status': 'OK'}));
        }
      case 'cc_agent_session':
        socket.add(
          jsonEncode({
            'seq_reply': seq,
            'status': 'OK',
            'data': {
              'agent_id': 7,
              'channels': [
                {'channel': 'call', 'state': callChannelState},
              ],
            },
          }),
        );
    }
  }

  void send(Map<String, dynamic> event) => sockets.last.add(jsonEncode(event));

  Future<void> dropAll() async {
    for (final s in sockets) {
      await s.close();
    }
  }

  Future<void> close() async {
    await dropAll();
    await http.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
  });

  late _FakeWebitel server;
  late WebitelSocket socket;
  late List<Map<String, dynamic>> stops;

  setUp(() async {
    server = _FakeWebitel();
    await server.start();
    stops = [];
    socket = WebitelSocket(
      config: WebitelSocketConfig(
        url: server.url,
        baseUrl: 'https://example.com',
        token: 'test-token-agent',
      ),
      storage: FakeStorage(),
    );
    socket.onScreenRecordStart = (_) async => true;
    socket.onScreenRecordStop = (body) async => stops.add(body);
  });

  tearDown(() async {
    await socket.disconnect();
    await server.close();
  });

  // A channel event that puts the agent into post-processing: recording active.
  Map<String, dynamic> processing() => {
    'event': 'channel',
    'data': {'status': 'processing', 'attempt_id': '42'},
  };

  test('authentication succeeds on an OK reply', () async {
    await socket.connect();
    await socket.authenticate();
    final session = await socket.getAgentSession();
    expect(session.agentId, 7);
  });

  test('a refused token is reported as rejected, not as success', () async {
    server.rejectAuth = true;
    await socket.connect();
    await expectLater(
      socket.authenticate(),
      throwsA(isA<AuthRejectedException>()),
    );
  });

  test('concurrent authenticate calls share one challenge', () async {
    await socket.connect();
    await Future.wait([socket.authenticate(), socket.authenticate()]);
    expect(server.authAttempts, 1);
  });

  test('a WS drop keeps the recording and stops it after reconnect when '
      'the call ended meanwhile', () async {
    socket.onScreenRecordStop = (body) async => stops.add(body);
    await socket.connect();
    await socket.authenticate();
    socket.initServices(
      screenshot: ScreenshotSenderService(
        baseUrl: 'https://example.com',
        storage: FakeStorage(),
      ),
      storage: FakeStorage(),
    );
    socket.onScreenRecordStart = (_) async => true;
    socket.onScreenRecordStop = (body) async => stops.add(body);

    server.send(processing());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await server.dropAll();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(stops, isEmpty, reason: 'recording survives the drop');

    server.callChannelState = 'waiting';
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(stops.map((s) => s['reason']), ['call_ended_while_disconnected']);
  });

  test(
    'a WS drop during an ongoing call does not stop the recording',
    () async {
      await socket.connect();
      await socket.authenticate();
      socket.initServices(
        screenshot: ScreenshotSenderService(
          baseUrl: 'https://example.com',
          storage: FakeStorage(),
        ),
        storage: FakeStorage(),
      );
      socket.onScreenRecordStart = (_) async => true;
      socket.onScreenRecordStop = (body) async => stops.add(body);

      server.send(processing());
      await Future<void>.delayed(const Duration(milliseconds: 100));

      server.callChannelState = 'processing';
      await server.dropAll();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(stops, isEmpty);
    },
  );

  test('nothing reconnects after disconnect', () async {
    await socket.connect();
    await socket.authenticate();
    await server.dropAll();
    await socket.disconnect();
    final before = server.sockets.length;
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(server.sockets.length, before);
  });
}
