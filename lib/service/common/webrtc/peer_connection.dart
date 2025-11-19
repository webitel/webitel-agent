import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/core/logger.dart';

Future<RTCPeerConnection> createPeerConnectionWithConfig(
  List<Map<String, dynamic>> iceServers,
) async {
  final config = {
    'sdpSemantics': 'unified-plan',
    'iceServers': iceServers,
    'encodedInsertableStreams': false,
    'enableCpuOveruseDetection': false,
    'media': {
      'video': {'hardwareAcceleration': true},
    },
  };

  logger.debug('[PeerConnection] Creating peer connection...');
  final pc = await createPeerConnection(config);

  logger.debug('[PeerConnection] Adding video transceiver...');
  await pc.addTransceiver(
    kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
    init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
  );

  return pc;
}
