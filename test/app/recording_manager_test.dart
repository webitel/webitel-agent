import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webitel_desk_track/app/recording_manager.dart';

import '../support/fakes.dart';

void main() {
  late FakeRecorderFactory factory;
  late RecordingManager manager;

  setUp(() {
    factory = FakeRecorderFactory();
    manager = RecordingManager(storage: FakeStorage(), factory: factory);
  });

  test(
    'a slow stop of the previous call does not orphan the next one',
    () async {
      await manager.start('call-a', type: RecordingType.call);
      final a = factory.created.single;
      a.stopGate = Completer<void>();

      final stopA = manager.stopAll('hangup');
      final startB = manager.start('call-b', type: RecordingType.call);
      await Future<void>.delayed(Duration.zero);
      a.stopGate.complete();
      await stopA;
      expect(await startB, isTrue);

      final b = factory.created.last;
      expect(b.id, 'call-b');
      expect(manager.recorderOf(RecordingType.call), same(b));

      await manager.stopAll('hangup');
      expect(b.isRunning, isFalse);
      expect(manager.recorderOf(RecordingType.call), isNull);
    },
  );

  test(
    'starting while a start is in flight stops the first recorder',
    () async {
      factory.configure = (r) => r.startGate = Completer<void>();
      final first = manager.start('call-a', type: RecordingType.call);
      final second = manager.start('call-b', type: RecordingType.call);
      await Future<void>.delayed(Duration.zero);

      factory.created.first.startGate.complete();
      expect(await first, isTrue);
      await Future<void>.delayed(Duration.zero);
      factory.created.last.startGate.complete();
      expect(await second, isTrue);

      expect(factory.created, hasLength(2));
      expect(factory.created.first.isRunning, isFalse);
      expect(
        manager.recorderOf(RecordingType.call),
        same(factory.created.last),
      );
    },
  );

  test('an unexpected stop clears only its own recorder', () async {
    await manager.start('call-a', type: RecordingType.call);
    final a = factory.created.single;
    await manager.start('call-b', type: RecordingType.call);
    final b = factory.created.last;

    a.onUnexpectedStop?.call('ice_failed');
    expect(manager.recorderOf(RecordingType.call), same(b));

    b.onUnexpectedStop?.call('ice_failed');
    expect(manager.recorderOf(RecordingType.call), isNull);
  });

  test('start reports failure and keeps nothing registered', () async {
    factory.configure = (r) => r.failStart = true;
    expect(await manager.start('call-a', type: RecordingType.call), isFalse);
    expect(manager.recorderOf(RecordingType.call), isNull);
  });

  test('start without a token reports failure', () async {
    manager = RecordingManager(
      storage: FakeStorage(token: null),
      factory: factory,
    );
    expect(await manager.start('call-a', type: RecordingType.call), isFalse);
    expect(factory.created, isEmpty);
  });

  test('no recording starts after shutdown', () async {
    await manager.start('call-a', type: RecordingType.call);
    await manager.stopAllAndUpload();
    expect(factory.created.single.isRunning, isFalse);

    expect(await manager.start('call-b', type: RecordingType.call), isFalse);
    expect(factory.created, hasLength(1));
  });

  test('call and screen recordings are independent', () async {
    await manager.start('call-a', type: RecordingType.call);
    await manager.start('manual', type: RecordingType.screen);
    expect(manager.recorderOf(RecordingType.call)?.toString(), isNotNull);
    expect(manager.recorderOf(RecordingType.screen), isNotNull);

    await manager.stopAll('hangup');
    expect(factory.created.every((r) => !r.isRunning), isTrue);
  });
}
