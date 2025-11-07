import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/common/webrtc/capturer.dart';
import 'package:webitel_desk_track/service/common/webrtc/peer_connection.dart';
import 'package:webitel_desk_track/service/common/webrtc/signaling.dart';
import 'package:webitel_desk_track/service/recording/recorder.dart';

class StreamRecorder implements Recorder {
  final String callId;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;

  RTCPeerConnection? pc;
  List<MediaStream> streams = [];
  String? _sessionID;

  StreamRecorder({
    required this.callId,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
  });

  @override
  Future<void> start({required String recordingId}) async {
    logger.info('[StreamRecorder] Starting stream for $callId');
    pc = await createPeerConnectionWithConfig(iceServers);

    pc!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logger.warn('[StreamRecorder] ICE failed, stopping...');
        stop();
      }
    };

    if (Platform.isWindows) {
      streams = await captureAllDesktopScreensWindows();
    } else {
      final stream = await captureDesktopScreen();
      if (stream != null) streams = [stream];
    }

    if (streams.isEmpty) throw Exception('No screens captured');

    for (final s in streams) {
      for (final t in s.getTracks()) {
        pc!.addTrack(t, s);
      }
    }

    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);

    final desc = await pc!.getLocalDescription();
    if (desc == null) throw Exception('Local SDP is null');

    final response = await sendSDPToServer(
      url: sdpResolverUrl,
      token: token,
      offer: desc,
      id: callId,
    );

    _sessionID = response.streamId;
    await pc!.setRemoteDescription(response.answer);
    logger.info('[StreamRecorder] Stream started (id=$_sessionID)');
  }

  @override
  Future<void> stop() async {
    logger.info('[StreamRecorder] Stopping stream...');
    if (_sessionID != null) {
      try {
        await stopStreamOnServer(
          url: '$sdpResolverUrl/$_sessionID',
          token: token,
          id: _sessionID!,
        );
      } catch (e) {
        logger.warn('[StreamRecorder] stopStreamOnServer failed: $e');
      }
    }

    for (final s in streams) {
      for (var t in s.getTracks()) {
        t.stop();
      }
    }
    streams.clear();
    await pc?.close();
    pc = null;
  }

  @override
  Future<void> upload() async {
    // WebRTC streaming — upload not applicable
  }

  @override
  Future<void> cleanup() async {
    // Nothing to cleanup for live streams
  }
}
