import 'dart:async';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/config/config.dart';
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
      onStart: (body) {
        final rootId = body['root_id']?.toString() ?? 'unknown_root';
        _onStart(rootId, type: RecordingType.screen);
      },
      onStop: (body) {
        final rootId = body['root_id']?.toString() ?? 'unknown_root';
        _onStop(rootId, type: RecordingType.screen);
      },
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

    final recorder =
        appConfig.videoSaveLocally
            ? LocalVideoRecorder(
              callId: recordingId,
              agentToken: token,
              baseUrl: appConfig.baseUrl,
              channel: 'screenrecording',
            )
            : StreamRecorder(
              callId: recordingId,
              token: token,
              sdpResolverUrl: AppConfig.instance.webrtcSdpUrl,
              iceServers: appConfig.webrtcIceServers,
            );

    // BIND RECONNECTION LOGIC
    recorder.onConnectionFailed = () => _handleReconnection(recordingId, type);

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

  /// Handles automatic recovery when WebRTC connection drops
  void _handleReconnection(String id, RecordingType type) {
    // If recorder is already null, it means we stopped manually (hangup)
    if (_recorders[type] == null) return;

    logger.warn(
      '[RecordingManager] Recovery: Network issue on $id. Retrying in 5s...',
    );

    // 1. Clean up current failed instance without removing global timers
    _onStop(id, type: type, isRecovering: true);

    // 2. Schedule a fresh start
    Timer(const Duration(seconds: 5), () {
      // Ensure we still have an active session context (e.g., call hasn't ended)
      logger.info('[RecordingManager] Recovery: Attempting restart for $id');
      _onStart(id, type: type);
    });
  }

  Future<void> _onStop(
    String id, {
    required RecordingType type,
    bool isRecovering = false,
  }) async {
    final recorder = _recorders[type];
    if (recorder == null) return;

    // Do not cancel global limit timer if we are just recovering from network drop
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
      logger.info(
        '[RecordingManager] ${isRecovering ? "Paused" : "Stopped"} $type → $id',
      );
    } catch (e) {
      logger.warn('[RecordingManager] Shutdown error: $e');
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
