import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:webitel_desk_track/ws/core/connection_manager.dart';

class _Server {
  late final HttpServer http;
  final sockets = <WebSocket>[];
  Duration acceptDelay = Duration.zero;

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      await Future<void>.delayed(acceptDelay);
      final socket = await WebSocketTransformer.upgrade(request);
      // Listening is what makes dart:io answer pings with pongs.
      socket.listen((_) {}, onError: (_) {});
      sockets.add(socket);
    });
  }

  String get url => 'ws://127.0.0.1:${http.port}';

  Future<void> close() async {
    for (final s in sockets) {
      await s.close();
    }
    await http.close(force: true);
  }
}

void main() {
  late _Server server;
  late List<dynamic> received;
  late int disconnects;
  late WsConnectionManager manager;

  setUp(() async {
    server = _Server();
    await server.start();
    received = [];
    disconnects = 0;
    manager = WsConnectionManager(
      onMessage: received.add,
      onDisconnected: () => disconnects++,
    );
  });

  tearDown(() async {
    manager.dispose();
    await server.close();
  });

  test('concurrent connect calls share one connection', () async {
    server.acceptDelay = const Duration(milliseconds: 100);
    await Future.wait([
      manager.connect(server.url),
      manager.connect(server.url),
      manager.connect(server.url),
    ]);

    expect(manager.isConnected, isTrue);
    expect(server.sockets, hasLength(1));
  });

  test('ready waits for an in-flight connect', () async {
    server.acceptDelay = const Duration(milliseconds: 100);
    final connecting = manager.connect(server.url);
    await manager.ready;
    expect(manager.isConnected, isTrue);
    await connecting;
  });

  test('ready returns at once when nothing is connecting', () async {
    await manager.ready.timeout(const Duration(milliseconds: 200));
    expect(manager.isConnected, isFalse);
  });

  test('server close is reported once and allows reconnecting', () async {
    await manager.connect(server.url);
    await server.sockets.single.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(manager.isConnected, isFalse);
    expect(disconnects, 1);

    await manager.connect(server.url);
    expect(manager.isConnected, isTrue);
    server.sockets.last.add('{"event":"hello"}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(received, ['{"event":"hello"}']);
  });

  test('dispose during connect leaves the manager disconnected', () async {
    server.acceptDelay = const Duration(milliseconds: 150);
    final connecting = manager.connect(server.url);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    manager.dispose();

    await expectLater(connecting, throwsA(anything));
    expect(manager.isConnected, isFalse);
    expect(disconnects, 0);
  });

  test('drop reports a disconnect', () async {
    await manager.connect(server.url);
    manager.drop('AUTH_FAILED');
    expect(manager.isConnected, isFalse);
    expect(disconnects, 1);
  });

  test('a half-open connection is detected by keepalive pings', () async {
    manager.dispose();
    manager = WsConnectionManager(
      onMessage: received.add,
      onDisconnected: () => disconnects++,
      connector:
          (uri) => IOWebSocketChannel.connect(
            uri,
            pingInterval: const Duration(milliseconds: 100),
          ),
    );

    // TCP proxy to the real server that silently drops traffic once told to,
    // like a VPN or NAT that lost the connection without closing it.
    var blackhole = false;
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((client) async {
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.http.port,
      );
      client.listen((d) {
        if (!blackhole) upstream.add(d);
      });
      upstream.listen((d) {
        if (!blackhole) client.add(d);
      });
    });

    await manager.connect('ws://127.0.0.1:${proxy.port}');
    expect(manager.isConnected, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(manager.isConnected, isTrue, reason: 'pongs flow while healthy');

    blackhole = true;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(manager.isConnected, isFalse);
    expect(disconnects, 1);
    await proxy.close();
  });
}
