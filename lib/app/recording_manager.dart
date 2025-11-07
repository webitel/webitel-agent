import 'dart:async';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/service/common/webrtc/config.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/recorder.dart';
import 'package:webitel_desk_track/service/recording/recorder.dart';
import 'package:webitel_desk_track/service/recording/webrtc/webrtc_recorder.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:webitel_desk_track/ws/ws.dart';

enum RecordingType { call, screen }

class RecordingManager {
  final _recorders = <RecordingType, Recorder?>{
    RecordingType.call: null,
    RecordingType.screen: null,
  };

  final _timers = <RecordingType, Map<String, Timer>>{
    RecordingType.call: {},
    RecordingType.screen: {},
  };

  // ---------------------------------------------------------------------------
  // Socket binding
  // ---------------------------------------------------------------------------

  void attachSocket(WebitelSocket socket) {
    socket.onCallEvent(
      onRinging: (callId) => _onStart(callId, type: RecordingType.call),
      onHangup: (callId) => _onStop(callId, type: RecordingType.call),
    );

    socket.onScreenRecordEvent(
      onStart: (body) => _onStart(body['root_id'], type: RecordingType.screen),
      onStop: (body) => _onStop(body['root_id'], type: RecordingType.screen),
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _onStart(String? id, {required RecordingType type}) async {
    final appConfig = AppConfig.instance;
    final token = await SecureStorageService().readAccessToken() ?? '';
    final recordingId = id ?? DateTime.now().millisecondsSinceEpoch.toString();

    // Ensure previous recorder stopped
    await _recorders[type]?.stop();

    final isScreen = type == RecordingType.screen;
    final recorder =
        appConfig.videoSaveLocally
            ? LocalVideoRecorder(
              callId: recordingId,
              agentToken: token,
              baseUrl: appConfig.baseUrl,
              channel: isScreen ? 'screensharing' : 'call',
            )
            : StreamRecorder(
              callId: recordingId,
              token: token,
              sdpResolverUrl: WebRTCConfig.fromEnv().sdpUrl,
              iceServers: appConfig.webrtcIceServers,
            );

    _recorders[type] = recorder;

    await recorder.start(recordingId: recordingId);

    // Set auto-stop timer
    final t = Timer(
      Duration(seconds: appConfig.maxCallRecordDuration),
      () => _onStop(recordingId, type: type),
    );
    _timers[type]![recordingId] = t;

    logger.info('[RecordingManager] Started $type → $recordingId');
  }

  Future<void> _onStop(String id, {required RecordingType type}) async {
    final recorder = _recorders[type];
    if (recorder == null) return;

    _timers[type]![id]?.cancel();
    _timers[type]!.remove(id);

    try {
      await recorder.stop();
      await recorder.upload();
      await recorder.cleanup();
      logger.info('[RecordingManager] Stopped $type → $id');
    } catch (e, st) {
      logger.warn('[RecordingManager] stop/upload error ($type): $e\n$st');
    } finally {
      _recorders[type] = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Stop all
  // ---------------------------------------------------------------------------

  Future<void> stopAllAndUpload() async {
    logger.info('[RecordingManager] stopAllAndUpload called');

    for (final map in _timers.values) {
      for (final t in map.values) {
        t.cancel();
      }
      map.clear();
    }

    for (final type in RecordingType.values) {
      final recorder = _recorders[type];
      if (recorder == null) continue;

      try {
        await recorder.stop();
        await recorder.upload();
        await recorder.cleanup();
      } catch (e, st) {
        logger.warn('[RecordingManager] error stopping $type: $e\n$st');
      } finally {
        _recorders[type] = null;
      }
    }
  }
}
