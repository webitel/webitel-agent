import 'dart:async';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/common/webrtc/capturer.dart';
import 'package:webitel_desk_track/service/common/webrtc/peer_connection.dart';
import 'package:webitel_desk_track/service/common/webrtc/signaling.dart';
import 'package:webitel_desk_track/service/recording/recorder.dart';
import 'package:webitel_desk_track/service/recording/webrtc/metrics.dart';

class StreamRecorder implements Recorder {
  final String callId;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;

  RTCPeerConnection? pc;
  List<MediaStream> streams = [];
  String? _sessionID;
  WebRTCMetricsReporter? _metricsReporter;

  StreamRecorder({
    required this.callId,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
  });

  @override
  void Function()? onConnectionFailed;

  @override
  Future<void> start({required String recordingId}) async {
    logger.info('[StreamRecorder] Initializing WebRTC session for $callId');
    pc = await createPeerConnectionWithConfig(iceServers);

    // Set up connection state listeners
    pc!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logger.warn('[StreamRecorder] ICE Connection failure: $state');
        onConnectionFailed?.call();
      }
    };

    pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (AppConfig.instance.webrtcEnableMetrics) {
          _metricsReporter = WebRTCMetricsReporter(pc!);
          _metricsReporter!.start();
        }
      }
    };

    // Capture screen sources based on platform
    if (Platform.isWindows) {
      streams = await captureAllDesktopScreensWindows(
        FFmpegMode.recording,
        pc!,
      );
    } else {
      final stream = await captureDesktopScreen();
      if (stream != null) {
        streams = [stream];
      }
    }

    if (streams.isEmpty) {
      throw Exception('No display sources available for capture');
    }

    // Add tracks and set encoding parameters
    for (final stream in streams) {
      for (final track in stream.getTracks()) {
        final sender = await pc!.addTrack(track, stream);
        if (track.kind == 'video') {
          await _configureVideoEncoding(sender);
        }
      }
    }

    // SDP Handshake
    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);

    final localDesc = await pc!.getLocalDescription();
    if (localDesc == null) throw Exception('Failed to generate local SDP');

    final response = await sendSDPToServer(
      url: sdpResolverUrl,
      token: token,
      offer: localDesc,
      id: callId,
    );

    _sessionID = response.streamId;
    await pc!.setRemoteDescription(response.answer);
    logger.info('[StreamRecorder] Recording session established: $_sessionID');
  }

  Future<void> _configureVideoEncoding(RTCRtpSender sender) async {
    final params = sender.parameters;
    if (params.encodings!.isEmpty) params.encodings!.add(RTCRtpEncoding());

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
    logger.info('[StreamRecorder] Closing session for $callId');
    _metricsReporter?.stop();

    await stopStereoAudioFFmpeg(FFmpegMode.recording);

    if (_sessionID != null) {
      try {
        await stopStreamOnServer(
          url: '$sdpResolverUrl/$_sessionID',
          token: token,
          id: _sessionID!,
        );
      } catch (e) {
        logger.warn('[StreamRecorder] Server-side termination failed: $e');
      }
    }

    for (final stream in streams) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
    }
    streams.clear();

    await pc?.close();
    pc = null;
  }

  @override
  Future<void> upload() async {} // Live streaming: data sent in real-time

  @override
  Future<void> cleanup() async {} // Live streaming: no local files to clean
}
