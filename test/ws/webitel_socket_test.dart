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
  int authErrorCode = 401;
  bool failAgentSession = false;
  bool dropOnAgentSession = false;
  String callChannelState = 'waiting';
  String outCallChannelState = 'waiting';
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
              'error': {
                'id': 'auth',
                'status': 'Unauthorized',
                'code': authErrorCode,
              },
            }),
          );
        } else {
          socket.add(jsonEncode({'seq_reply': seq, 'status': 'OK'}));
        }
      case 'cc_agent_session':
        if (dropOnAgentSession) {
          socket.close();
          return;
        }
        if (failAgentSession) {
          socket.add(
            jsonEncode({
              'seq_reply': seq,
              'status': 'FAIL',
              'error': {'id': 'internal', 'status': 'Internal', 'code': 500},
            }),
          );
          return;
        }
        socket.add(
          jsonEncode({
            'seq_reply': seq,
            'status': 'OK',
            'data': {
              'agent_id': 7,
              'channels': [
                {'channel': 'call', 'state': callChannelState},
                {'channel': 'out_call', 'state': outCallChannelState},
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
    WebitelSocket.recordingGrace = const Duration(seconds: 60);
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

  test('a server error on auth is transient, not a rejected token', () async {
    server.rejectAuth = true;
    server.authErrorCode = 500;
    await socket.connect();
    await expectLater(
      socket.authenticate(),
      throwsA(isA<SocketUnavailableException>()),
    );
  });

  test('a token refused on reconnect asks for a new login', () async {
    var reloginRequests = 0;
    socket.onAuthRejected = () => reloginRequests++;
    await socket.connect();
    await socket.authenticate();

    server.rejectAuth = true;
    await server.dropAll();
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(reloginRequests, 1);
  });

  test('a lost recorder is restarted while the call is active', () async {
    await socket.connect();
    await socket.authenticate();
    socket.initServices(
      screenshot: ScreenshotSenderService(
        baseUrl: 'https://example.com',
        storage: FakeStorage(),
      ),
      storage: FakeStorage(),
    );
    final ensured = <String>[];
    socket.onScreenRecordEnsure = (body) async {
      ensured.add(body['root_id'] as String);
      return true;
    };

    server.send(processing());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    socket.notifyRecordingLost('call-1');
    await Future<void>.delayed(const Duration(milliseconds: 5500));
    expect(ensured, ['call-1']);
  });

  test('a failed restart of a lost recorder is retried', () async {
    await socket.connect();
    await socket.authenticate();
    socket.initServices(
      screenshot: ScreenshotSenderService(
        baseUrl: 'https://example.com',
        storage: FakeStorage(),
      ),
      storage: FakeStorage(),
    );
    var attempts = 0;
    socket.onScreenRecordEnsure = (_) async => ++attempts >= 2;

    server.send(processing());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    socket.notifyRecordingLost('call-1');
    await Future<void>.delayed(const Duration(milliseconds: 15500));
    expect(attempts, 2, reason: 'retried once after a failure, then stopped');
  });

  Future<void> startRecordingCall() async {
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
  }

  test(
    'a failing agent session after reconnect keeps the connection',
    () async {
      await startRecordingCall();
      server.failAgentSession = true;
      final before = server.sockets.length;
      await server.dropAll();
      await Future<void>.delayed(const Duration(seconds: 6));

      expect(
        server.sockets.length,
        before + 1,
        reason: 'one reconnect, no loop',
      );
      expect(stops, isEmpty, reason: 'recording kept for the periodic check');
    },
  );

  test('a drop during the session check keeps the grace cut-off', () async {
    // Longer than the first retry (2s), so the reconnect and its session
    // request happen while the grace timer is still pending.
    WebitelSocket.recordingGrace = const Duration(seconds: 3);
    await startRecordingCall();
    server.dropOnAgentSession = true;
    await server.dropAll();
    await Future<void>.delayed(const Duration(seconds: 7));

    expect(stops.map((s) => s['reason']), contains('network_loss_cleanup'));
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

  for (final busyChannel in ['call', 'out_call']) {
    test('a WS drop while $busyChannel is busy does not stop the '
        'recording', () async {
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

      if (busyChannel == 'call') {
        server.callChannelState = 'processing';
      } else {
        server.outCallChannelState = 'processing';
      }
      final before = server.sockets.length;
      await server.dropAll();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(server.sockets.length, before + 1, reason: 'reconnected');
      expect(stops, isEmpty);
    });
  }

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
