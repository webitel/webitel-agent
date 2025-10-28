import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';

Future<RTCPeerConnection> createPeerConnectionWithConfig(
  List<Map<String, dynamic>> iceServers,
) async {
  final config = {'iceServers': iceServers};

  logger.debug('[PeerConnection] Creating peer connection...');
  final pc = await createPeerConnection(config);

  logger.debug('[PeerConnection] Adding video transceiver...');
  await pc.addTransceiver(
    kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
    init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
  );

  return pc;
}
