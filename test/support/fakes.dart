import 'dart:async';

import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/common/recorder/factory.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';

class FakeStorage implements IStorageService {
  String? token;
  int? agentId;

  FakeStorage({this.token = 'test-token-agent', this.agentId = 7});

  @override
  Future<String?> readAccessToken() async => token;
  @override
  Future<void> writeAccessToken(String value) async => token = value;
  @override
  Future<void> deleteAccessToken() async => token = null;
  @override
  Future<int?> readAgentId() async => agentId;
  @override
  Future<void> writeAgentId(int value) async => agentId = value;
  @override
  Future<void> deleteAgentId() async => agentId = null;
  @override
  Future<void> flush() async {
    token = null;
    agentId = null;
  }
}

class FakeRecorder implements RecorderI {
  final String id;
  Completer<void> startGate = Completer<void>()..complete();
  Completer<void> stopGate = Completer<void>()..complete();
  bool failStart = false;
  int starts = 0;
  int stops = 0;

  FakeRecorder(this.id);

  bool get isRunning => starts > stops;

  @override
  void Function(String reason)? onUnexpectedStop;

  @override
  Future<void> start({required String recordingId}) async {
    starts++;
    await startGate.future;
    if (failStart) throw Exception('capture failed');
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate.future;
  }

  @override
  Future<void> upload() async {}

  @override
  Future<void> cleanup() async {}
}

class FakeRecorderFactory extends RecorderFactory {
  final created = <FakeRecorder>[];
  void Function(FakeRecorder recorder)? configure;

  FakeRecorderFactory() : super(FakeStorage());

  @override
  RecorderI create({required String id, required String token}) {
    final recorder = FakeRecorder(id);
    configure?.call(recorder);
    created.add(recorder);
    return recorder;
  }
}
