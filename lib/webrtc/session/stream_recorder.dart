import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/webrtc/core/capturer.dart' hide logger;
import 'package:webitel_agent_flutter/webrtc/core/peer_connection.dart'
    hide logger;
import 'package:webitel_agent_flutter/webrtc/core/signaling.dart' hide logger;

class StreamRecorder {
  final String id;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;

  RTCPeerConnection? pc;
  MediaStream? stream;

  bool get isStreaming => pc != null && stream != null;

  StreamRecorder({
    required this.id,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
  });

  Future<void> start() async {
    logger.info('[StreamRecorder] Starting stream sender for call $id');

    pc = await createPeerConnectionWithConfig(iceServers);

    pc!.onIceConnectionState = (state) {
      logger.debug('[StreamRecorder] ICE connection state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logger.warn(
          '[StreamRecorder] ICE disconnected/failed, stopping stream...',
        );
        stop();
      }
    };

    stream = await captureDesktopScreen();

    if (stream == null) {
      logger.error('[StreamRecorder] Could not capture screen');
      throw Exception('Screen capture failed');
    }

    for (var track in stream!.getTracks()) {
      final settings = track.getSettings();

      logger.debug(
        '[Capturer] Track settings: '
        'width=${settings['width']}, '
        'height=${settings['height']}, '
        'frameRate=${settings['frameRate']}',
      );

      pc!.addTrack(track, stream!);
    }

    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);
    logger.debug('[StreamRecorder] Created SDP offer');

    final localDescription = await pc!.getLocalDescription();

    if (localDescription == null) {
      throw Exception('Local SDP is null');
    }

    final remoteSdp = await sendSDPToServer(
      url: sdpResolverUrl,
      token: token,
      offer: localDescription,
      id: id,
    );

    await pc!.setRemoteDescription(remoteSdp);
    logger.info('[StreamRecorder] Set remote SDP, streaming started');
  }

  void stop() {
    logger.info('[StreamRecorder] Stopping stream sender...');
    stream?.getTracks().forEach((t) {
      logger.debug('[StreamRecorder] Stopping track: ${t.kind}');
      t.stop();
    });

    stream = null;

    if (pc != null) {
      pc!.close();
      logger.debug('[StreamRecorder] Closed peer connection');
      pc = null;
    }
  }
}
