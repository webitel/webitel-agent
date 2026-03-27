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
    await _cleanupInternal();
    _isStopping = false;

    final logId = recordingId.isNotEmpty ? recordingId : callId;
    logger.info('[StreamRecorder] Initializing WebRTC for $logId');

    _maxDurationTimer = Timer(const Duration(hours: 1), () {
      logger.warn('[StreamRecorder] SAFETY_TIMEOUT reached. Force stopping.');
      stop();
    });

    try {
      pc = await createPeerConnectionWithConfig(iceServers);
      final currentPc = pc!;

      currentPc.onIceConnectionState = (RTCIceConnectionState state) {
        logger.debug('[StreamRecorder] ICE Connection State: ${state.name}');

        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          // [CRITICAL] Connection failed permanently. Kill the session.
          logger.error(
            '[StreamRecorder] ICE Failed. Permanent transport loss.',
          );
          stop();
        }

        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          // [WARN] Transient disconnect. Let's wait a bit before giving up.
          logger.warn(
            '[StreamRecorder] ICE Disconnected. Waiting for recovery...',
          );

          Future.delayed(const Duration(seconds: 10), () {
            // Check if it's still disconnected after 10 seconds
            if (pc?.iceConnectionState ==
                    RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                pc?.iceConnectionState ==
                    RTCIceConnectionState.RTCIceConnectionStateFailed) {
              logger.warn(
                '[StreamRecorder] ICE recovery timeout. Closing session.',
              );
              stop();
            }
          });
        }
      };

      if (Platform.isWindows) {
        streams = await captureAllDesktopScreensWindows(
          FFmpegMode.recording,
          currentPc,
        );
      } else {
        final stream = await captureDesktopScreen();
        if (stream != null) streams = [stream];
      }

      if (_isStopping || streams.isEmpty) throw Exception('No sources found');

      for (final stream in streams) {
        for (final track in stream.getTracks()) {
          final sender = await currentPc.addTrack(track, stream);
          if (track.kind == 'video') await _configureVideoEncoding(sender);
        }
      }

      final offer = await currentPc.createOffer();
      if (_isStopping) return;
      await currentPc.setLocalDescription(offer);

      int waitCount = 0;
      while (currentPc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          waitCount < 20) {
        if (_isStopping) return;
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }

      final localDesc = await currentPc.getLocalDescription();
      if (localDesc == null) throw Exception('SDP generation failed');

      final response = await sendSDPToServer(
        url: sdpResolverUrl,
        token: token,
        offer: localDesc,
        id: logId,
        storage: _storage,
      );

      if (_isStopping) return;
      _sessionID = response.streamId;
      await currentPc.setRemoteDescription(response.answer);

      logger.info('[StreamRecorder] Established Session: $_sessionID');
    } catch (e, st) {
      if (!_isStopping) {
        logger.error('[StreamRecorder] Start failed', e, st);
        await _cleanupInternal();
        rethrow;
      }
    }
  }

  Future<void> _configureVideoEncoding(RTCRtpSender sender) async {
    final params = sender.parameters;
    if (params.encodings!.isEmpty) params.encodings!.add(RTCRtpEncoding());

    params.encodings![0]
      ..maxBitrate = 2500000
      ..minBitrate = 500000
      ..maxFramerate = AppConfig.instance.framerate;

    params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
    await sender.setParameters(params);
  }

  @override
  Future<void> stop() async {
    if (_isStopping) return;
    _isStopping = true;
    _maxDurationTimer?.cancel();
    logger.info('[StreamRecorder] Terminating session for $callId');
    await _cleanupInternal();
  }

  Future<void> _cleanupInternal() async {
    _maxDurationTimer?.cancel();
    await stopStereoAudioFFmpeg(FFmpegMode.recording);

    if (_sessionID != null) {
      try {
        await stopStreamOnServer(
          url: '$sdpResolverUrl/$_sessionID',
          token: token,
          id: _sessionID!,
        ).timeout(const Duration(seconds: 2));
      } catch (_) {}
      _sessionID = null;
    }

    for (final stream in streams) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
    }
    streams.clear();

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
