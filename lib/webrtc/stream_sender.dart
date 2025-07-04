import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/webrtc/signaling.dart';

import 'capturer.dart';
import 'peer_connection.dart';

class StreamSender {
  final String id;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;

  final logger = LoggerService();

  RTCPeerConnection? pc;
  MediaStream? stream;

  bool get isStreaming => pc != null && stream != null;

  StreamSender({
    required this.id,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
  });

  Future<void> start() async {
    logger.info('[StreamSender] Starting stream sender for call $id');

    pc = await createPeerConnectionWithConfig(iceServers);

    pc!.onIceConnectionState = (state) {
      logger.debug('[StreamSender] ICE connection state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logger.warn(
          '[StreamSender] ICE disconnected/failed, stopping stream...',
        );
        stop();
      }
    };

    stream = await captureDesktopScreen();
    if (stream == null) {
      logger.error('[StreamSender] Could not capture screen');
      throw Exception('Screen capture failed');
    }

    for (var track in stream!.getTracks()) {
      pc!.addTrack(track, stream!);
    }

    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);
    logger.debug('[StreamSender] Created SDP offer');

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
    logger.info('[StreamSender] Set remote SDP, streaming started');
  }

  void stop() {
    logger.info('[StreamSender] Stopping stream sender...');
    stream?.getTracks().forEach((t) {
      logger.debug('[StreamSender] Stopping track: ${t.kind}');
      t.stop();
    });

    stream = null;

    if (pc != null) {
      pc!.close();
      logger.debug('[StreamSender] Closed peer connection');
      pc = null;
    }
  }
}
