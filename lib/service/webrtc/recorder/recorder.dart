import 'dart:async';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/capturer.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/peer_connection.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/signaling.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';

class StreamRecorder implements RecorderI {
  final String callId;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;
  final IStorageService _storage;

  RTCPeerConnection? pc;
  List<MediaStream> streams = [];
  String? _sessionID;
  bool _isStopping = false;

  /// [GUARD] Safety timer to prevent infinite recording sessions
  Timer? _maxDurationTimer;

  StreamRecorder({
    required this.callId,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
    required IStorageService storage,
  }) : _storage = storage;

  @override
  Future<void> start({required String recordingId}) async {
    // [GUARD] Ensure any previous instance is fully disposed
    await _cleanupInternal();
    _isStopping = false;

    logger.info('[StreamRecorder] Initializing WebRTC session for $callId');

    // [LOGIC] Set 1-hour safety limit.
    // If no hangup event is received via socket, we force stop to release CPU/RAM.
    _maxDurationTimer = Timer(const Duration(hours: 1), () {
      logger.warn(
        '[StreamRecorder] SAFETY_TIMEOUT: Session $callId reached 1-hour limit. Force stopping.',
      );
      stop();
    });

    try {
      pc = await createPeerConnectionWithConfig(iceServers);

      pc!.onIceConnectionState = (state) {
        logger.debug('[StreamRecorder] onIceConnectionState: ${state.name}');

        // [LOGIC] Trigger recovery only if we are NOT intentionally stopping
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          if (!_isStopping) {
            logger.warn('[StreamRecorder] ICE Connection failure detected');
          }
        }
      };

      // [LOGIC] OS-specific screen capture
      if (Platform.isWindows) {
        streams = await captureAllDesktopScreensWindows(
          FFmpegMode.recording,
          pc!,
        );
      } else {
        final stream = await captureDesktopScreen();
        if (stream != null) streams = [stream];
      }

      if (streams.isEmpty) throw Exception('No display sources available');

      // [PROTOCOL] Map tracks to PeerConnection
      for (final stream in streams) {
        for (final track in stream.getTracks()) {
          final sender = await pc!.addTrack(track, stream);
          if (track.kind == 'video') {
            await _configureVideoEncoding(sender);
          }
        }
      }

      // [PROTOCOL] Generate SDP Offer
      final offer = await pc!.createOffer();
      await pc!.setLocalDescription(offer);

      // [WAIT] Wait for ICE gathering to complete (Max 2 seconds)
      int waitCount = 0;
      while (pc?.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          waitCount < 20) {
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }

      final localDesc = await pc!.getLocalDescription();
      if (localDesc == null) throw Exception('Failed to generate local SDP');

      // [SIGNALING] Exchange SDP with Webitel Server
      final response = await sendSDPToServer(
        url: sdpResolverUrl,
        token: token,
        offer: localDesc,
        id: callId,
        storage: _storage,
      );

      _sessionID = response.streamId;
      await pc!.setRemoteDescription(response.answer);

      logger.info('[StreamRecorder] Session established: $_sessionID');
    } catch (e, st) {
      logger.error('[StreamRecorder] Start failed', e, st);
      await _cleanupInternal();
      rethrow;
    }
  }

  Future<void> _configureVideoEncoding(RTCRtpSender sender) async {
    final params = sender.parameters;
    if (params.encodings!.isEmpty) params.encodings!.add(RTCRtpEncoding());

    // [LOGIC] Set bitrate and framerate from config
    params.encodings![0]
      ..maxBitrate = 4000000
      ..minBitrate = 500000
      ..maxFramerate = AppConfig.instance.framerate
      ..scaleResolutionDownBy = 1.0;

    params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
    await sender.setParameters(params);
  }

  @override
  Future<void> stop() async {
    if (_isStopping) return;
    _isStopping = true;

    // [GUARD] Cancel the safety timer as we are stopping normally
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;

    logger.info('[StreamRecorder] Terminating session for $callId');
    await _cleanupInternal();
  }

  /// [LOGIC] Centralized resource disposal
  Future<void> _cleanupInternal() async {
    // [GUARD] Ensure timer is disposed to prevent leaks
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;

    // 1. Stop FFmpeg audio capture
    await stopStereoAudioFFmpeg(FFmpegMode.recording);

    // 2. Notify backend to release stream resources
    if (_sessionID != null) {
      try {
        await stopStreamOnServer(
          url: '$sdpResolverUrl/$_sessionID',
          token: token,
          id: _sessionID!,
        ).timeout(const Duration(seconds: 2));
      } catch (e) {
        logger.warn(
          '[StreamRecorder] Server-side cleanup failed (Normal on network loss)',
        );
      }
      _sessionID = null;
    }

    // 3. Force stop all media tracks (Releases UI recording indicators)
    for (final stream in streams) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
    }
    streams.clear();

    // 4. Close PeerConnection and free memory
    if (pc != null) {
      await pc!.close();
      pc = null;
    }
  }

  @override
  Future<void> upload() async {}

  @override
  Future<void> cleanup() async => await _cleanupInternal();
}
