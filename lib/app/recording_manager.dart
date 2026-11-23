import 'dart:async';

import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/common/recorder/factory.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';
import 'package:webitel_desk_track/ws/webitel_socket.dart';

enum RecordingType { call, screen }

class RecordingManager {
  final IStorageService _storage;
  final RecorderFactory _factory;

  RecordingManager({required IStorageService storage, RecorderFactory? factory})
    : _storage = storage,
      _factory = factory ?? RecorderFactory(storage);

  final _recorders = <RecordingType, RecorderI?>{
    RecordingType.call: null,
    RecordingType.screen: null,
  };

  // Start and stop of one type run strictly one after another, so a slow stop
  // of the previous call can never clear the recorder of the next one.
  final _queues = <RecordingType, Future<void>>{};

  WebitelSocket? _socket;
  bool _closed = false;

  RecorderI? recorderOf(RecordingType type) => _recorders[type];

  void attachSocket(WebitelSocket socket) {
    logger.info('[RecordingManager] Binding to socket events');
    _socket = socket;

    socket.onScreenRecordStart = (body) {
      final rootId =
          body['root_id']?.toString() ??
          'session_${DateTime.now().millisecondsSinceEpoch}';
      final type =
          body.containsKey('call_id')
              ? RecordingType.call
              : RecordingType.screen;
      return start(rootId, type: type);
    };

    socket.onScreenRecordStop = (body) => stopAll('socket_signal');
  }

  Future<bool> start(String id, {required RecordingType type}) {
    final completer = Completer<bool>();
    _enqueue(type, () async {
      try {
        completer.complete(await _start(id, type));
      } catch (_) {
        completer.complete(false);
        rethrow;
      }
    });
    return completer.future;
  }

  Future<void> stopAll(String reason) => Future.wait(
    RecordingType.values.map(
      (type) => _enqueue(type, () => _stop(reason, type)),
    ),
  );

  Future<void> stopAllAndUpload() async {
    _closed = true;
    if (_socket != null) {
      _socket!.onScreenRecordStart = null;
      _socket!.onScreenRecordStop = null;
      _socket = null;
    }
    await stopAll('emergency');
  }

  Future<void> _enqueue(RecordingType type, Future<void> Function() op) {
    final previous = _queues[type] ?? Future<void>.value();
    final next = previous.then((_) => op()).catchError((
      Object e,
      StackTrace st,
    ) {
      logger.error('[RecordingManager] $type operation failed', e, st);
    });
    _queues[type] = next;
    return next;
  }

  Future<bool> _start(String id, RecordingType type) async {
    if (_closed) {
      logger.warn('[RecordingManager] Ignoring $type start after shutdown');
      return false;
    }

    final token = await _storage.readAccessToken() ?? '';
    if (token.isEmpty) {
      logger.error('[RecordingManager] Missing access token for $type');
      return false;
    }

    await _stop(id, type);

    final recorder = _factory.create(id: id, token: token);
    recorder.onUnexpectedStop = (reason) {
      if (!identical(_recorders[type], recorder)) return;
      logger.warn('[RecordingManager] $type session $id ended: $reason');
      _recorders[type] = null;
    };
    _recorders[type] = recorder;

    try {
      await recorder.start(recordingId: id);
      logger.info('[RecordingManager] Started $type session: $id');
      return true;
    } catch (e, st) {
      logger.error('[RecordingManager] Failed to start $type', e, st);
      if (identical(_recorders[type], recorder)) _recorders[type] = null;
      return false;
    }
  }

  Future<void> _stop(String id, RecordingType type) async {
    final recorder = _recorders[type];
    if (recorder == null) return;
    _recorders[type] = null;

    try {
      await recorder.stop();
      await recorder.upload();
      await recorder.cleanup();
      logger.info('[RecordingManager] Stopped $type session: $id');
    } catch (e) {
      logger.warn('[RecordingManager] Cleanup error for $id: $e');
    }
  }
}
