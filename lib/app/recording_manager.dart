import 'dart:async';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/common/recorder/factory.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';
import 'package:webitel_desk_track/ws/webitel_socket.dart';

enum RecordingType { call, screen }

class RecordingManager {
  final IStorageService _storage;
  final RecorderFactory _factory;

  RecordingManager({required IStorageService storage})
    : _storage = storage,
      _factory = RecorderFactory(storage);

  final _recorders = <RecordingType, RecorderI?>{
    RecordingType.call: null,
    RecordingType.screen: null,
  };

  final _timers = <RecordingType, Map<String, Timer>>{
    RecordingType.call: {},
    RecordingType.screen: {},
  };

  /// Binds socket events to recording lifecycle actions.
  void attachSocket(WebitelSocket socket) {
    logger.info('[RecordingManager] Binding to socket events');

    socket.onScreenRecordStart = (body) {
      final rootId =
          body['root_id']?.toString() ??
          'session_${DateTime.now().millisecondsSinceEpoch}';
      final type =
          body.containsKey('call_id')
              ? RecordingType.call
              : RecordingType.screen;
      _onStart(rootId, type: type);
    };

    socket.onScreenRecordStop = (body) {
      for (var type in RecordingType.values) {
        if (_recorders[type] != null) {
          _onStop('socket_signal', type: type);
        }
      }
    };
  }

  Future<void> _onStart(String id, {required RecordingType type}) async {
    final token = await _storage.readAccessToken() ?? '';
    if (token.isEmpty) {
      logger.error('[RecordingManager] Missing access token for $type');
      return;
    }

    // Ensure previous session of the same type is closed
    if (_recorders[type] != null) {
      await _onStop(id, type: type);
    }

    // Delegate creation to factory
    final recorder = _factory.create(id: id, token: token);
    _recorders[type] = recorder;

    try {
      await recorder.start(recordingId: id);
      logger.info('[RecordingManager] Started $type session: $id');

      _timers[type]![id] = Timer(
        Duration(seconds: AppConfig.instance.maxCallRecordDuration),
        () => _onStop(id, type: type),
      );
    } catch (e, st) {
      logger.error('[RecordingManager] Failed to start $type', e, st);
      _recorders[type] = null;
    }
  }

  Future<void> _onStop(
    String id, {
    required RecordingType type,
    bool isRecovering = false,
  }) async {
    final recorder = _recorders[type];
    if (recorder == null) return;

    if (!isRecovering) {
      _timers[type]![id]?.cancel();
      _timers[type]!.remove(id);
    }

    try {
      await recorder.stop();
      if (!isRecovering) {
        await recorder.upload();
        await recorder.cleanup();
      }
      logger.info('[RecordingManager] Stopped $type session: $id');
    } catch (e) {
      logger.warn('[RecordingManager] Cleanup error for $id: $e');
    } finally {
      _recorders[type] = null;
    }
  }

  Future<void> stopAllAndUpload() async {
    final activeTypes =
        _recorders.keys.where((t) => _recorders[t] != null).toList();
    await Future.wait(
      activeTypes.map((type) => _onStop('emergency', type: type)),
    );
  }
}
