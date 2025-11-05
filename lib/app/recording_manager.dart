// lib/service/recording/recording_manager.dart
import 'dart:async';

import 'package:webitel_agent_flutter/core/logger.dart';
import 'package:webitel_agent_flutter/service/common/webrtc/config.dart';
import 'package:webitel_agent_flutter/service/recording/webrtc/webrtc_recorder.dart';
import 'package:webitel_agent_flutter/service/recording/ffmpeg/ffmpeg_recorder.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';
import 'package:webitel_agent_flutter/config/config.dart';
import 'package:webitel_agent_flutter/storage/storage.dart';

/// Central manager that handles call and screen recordings.
/// It decides between local (ffmpeg) or stream (WebRTC) based on AppConfig.
class RecordingManager {
  LocalVideoRecorder? _callRecorder;
  StreamRecorder? _callStream;

  LocalVideoRecorder? _screenRecorder;
  StreamRecorder? _screenStream;

  final Map<String, Timer> _callTimers = {};
  final Map<String, Timer> _screenTimers = {};

  bool _initialized = false;

  void init() {
    _initialized = true;
  }

  /// Attach a socket so we can react on calls / screen events.
  void attachSocket(WebitelSocket socket) {
    socket.onCallEvent(
      onRinging: (callId) => _onCallStart(socket, callId),
      onHangup: (callId) => _onCallStop(callId),
    );

    socket.onScreenRecordEvent(
      onStart: (body) => _onScreenStart(socket, body),
      onStop: (body) => _onScreenStop(body),
    );
  }

  // ---------------- Call handlers ----------------
  Future<void> _onCallStart(WebitelSocket socket, String callId) async {
    logger.info('[RecordingManager] onCallStart: $callId');

    // stop any previous run
    _callStream?.stop();
    await _stopLocalRecorderIfExists(_callRecorder);

    final appConfig = AppConfig.instance;
    final token = await SecureStorageService().readAccessToken();

    if (appConfig.videoSaveLocally) {
      _callRecorder = LocalVideoRecorder(
        callId: callId,
        agentToken: token ?? '',
        baseUrl: appConfig.baseUrl,
        channel: 'screensharing',
      );
      try {
        await _callRecorder!.startRecording(recordingId: callId);
      } catch (e, st) {
        logger.error('[RecordingManager] call local start failed: $e\n$st');
      }
    } else {
      _callStream = StreamRecorder(
        callID: callId,
        token: token ?? '',
        sdpResolverUrl: WebRTCConfig.fromEnv().sdpUrl,
        iceServers: appConfig.webrtcIceServers,
      );
      try {
        await _callStream!.start();
      } catch (e, st) {
        logger.error('[RecordingManager] call stream start failed: $e\n$st');
      }
    }

    // schedule max duration stop
    _callTimers[callId]?.cancel();
    _callTimers[callId] = Timer(
      Duration(seconds: appConfig.maxCallRecordDuration),
      () => _onCallMaxDurationReached(callId),
    );
  }

  Future<void> _onCallStop(String callId) async {
    logger.info('[RecordingManager] onCallStop: $callId');

    _callTimers[callId]?.cancel();
    _callTimers.remove(callId);

    _callStream?.stop();
    _callStream = null;

    if (_callRecorder != null) {
      try {
        await _callRecorder!.stopRecording();
        final success = await _callRecorder!.uploadVideoWithRetry();
        if (!success) logger.error('[RecordingManager] call upload failed');
      } catch (e, st) {
        logger.error('[RecordingManager] stop/upload call error: $e\n$st');
      } finally {
        await LocalVideoRecorder.cleanupOldVideos();
        _callRecorder = null;
      }
    }
  }

  Future<void> _onCallMaxDurationReached(String callId) async {
    logger.info('[RecordingManager] call max duration reached: $callId');
    await _onCallStop(callId);
  }

  // ---------------- Screen handlers ----------------
  Future<void> _onScreenStart(WebitelSocket socket, Map body) async {
    logger.info('[RecordingManager] onScreenStart');

    _screenStream?.stop();
    await _stopLocalRecorderIfExists(_screenRecorder);

    final recordingId =
        body['root_id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final appConfig = AppConfig.instance;
    final token = await SecureStorageService().readAccessToken();

    if (appConfig.videoSaveLocally) {
      _screenRecorder = LocalVideoRecorder(
        callId: recordingId,
        agentToken: token ?? '',
        baseUrl: appConfig.baseUrl,
        channel: 'screensharing',
      );
      try {
        await _screenRecorder!.startRecording(recordingId: recordingId);
      } catch (e, st) {
        logger.error('[RecordingManager] screen local start failed: $e\n$st');
      }
    } else {
      _screenStream = StreamRecorder(
        callID: recordingId,
        token: token ?? '',
        sdpResolverUrl: WebRTCConfig.fromEnv().sdpUrl,
        iceServers: appConfig.webrtcIceServers,
      );
      try {
        await _screenStream!.start();
      } catch (e, st) {
        logger.error('[RecordingManager] screen stream start failed: $e\n$st');
      }
    }

    // schedule stop by max duration
    _screenTimers[recordingId]?.cancel();
    _screenTimers[recordingId] = Timer(
      Duration(seconds: appConfig.maxCallRecordDuration),
      () async {
        logger.info(
          '[RecordingManager] screen max duration reached: $recordingId',
        );
        await _onScreenStop({'root_id': recordingId});
      },
    );
  }

  Future<void> _onScreenStop(Map body) async {
    final recordingId = body['root_id'] ?? 'unknown';
    logger.info('[RecordingManager] onScreenStop: $recordingId');

    _screenTimers[recordingId]?.cancel();
    _screenTimers.remove(recordingId);

    _screenStream?.stop();
    _screenStream = null;

    if (_screenRecorder != null) {
      try {
        await _screenRecorder!.stopRecording();
        final success = await _screenRecorder!.uploadVideoWithRetry();
        if (!success) logger.error('[RecordingManager] screen upload failed');
      } catch (e, st) {
        logger.error('[RecordingManager] stop/upload screen error: $e\n$st');
      } finally {
        await LocalVideoRecorder.cleanupOldVideos();
        _screenRecorder = null;
      }
    }
  }

  // ---------------- Utilities ----------------
  Future<void> _stopLocalRecorderIfExists(LocalVideoRecorder? recorder) async {
    if (recorder == null) return;
    try {
      await recorder.stopRecording();
      final success = await recorder.uploadVideoWithRetry();
      if (!success) {
        logger.error('[RecordingManager] upload failed during swap');
      }
    } catch (e, st) {
      logger.error('[RecordingManager] swap/stop upload error: $e\n$st');
    } finally {
      await LocalVideoRecorder.cleanupOldVideos();
    }
  }

  /// Stop all active recorders and upload pending files.
  Future<void> stopAllAndUpload() async {
    logger.info('[RecordingManager] stopAllAndUpload called');

    // cancel timers
    for (final t in _callTimers.values) {
      t.cancel();
    }
    _callTimers.clear();
    for (final t in _screenTimers.values) {
      t.cancel();
    }
    _screenTimers.clear();

    // stop streams
    _callStream?.stop();
    _callStream = null;
    _screenStream?.stop();
    _screenStream = null;

    // stop local recorders & upload
    try {
      if (_callRecorder != null) {
        await _callRecorder!.stopRecording();
        await Future.delayed(const Duration(seconds: 1));
        await _callRecorder!.uploadVideoWithRetry();
      }
    } catch (e, st) {
      logger.warn('[RecordingManager] finishing call recorder error: $e\n$st');
    } finally {
      _callRecorder = null;
    }

    try {
      if (_screenRecorder != null) {
        await _screenRecorder!.stopRecording();
        await Future.delayed(const Duration(seconds: 1));
        await _screenRecorder!.uploadVideoWithRetry();
      }
    } catch (e, st) {
      logger.warn(
        '[RecordingManager] finishing screen recorder error: $e\n$st',
      );
    } finally {
      _screenRecorder = null;
    }

    // cleanup local temp files
    await LocalVideoRecorder.cleanupOldVideos();
  }
}
