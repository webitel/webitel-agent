import '../../config.dart';

class WebRTCConfig {
  final String sdpUrl;
  final int width;
  final int height;
  final int frameRate;

  const WebRTCConfig({
    required this.sdpUrl,
    required this.width,
    required this.height,
    required this.frameRate,
  });

  factory WebRTCConfig.fromEnv() {
    return WebRTCConfig(
      sdpUrl: AppConfig.webrtcSdpUrl,
      width: AppConfig.videoWidth,
      height: AppConfig.videoHeight,
      frameRate: AppConfig.videoFramerate,
    );
  }

  Map<String, dynamic> toConstraints() {
    return {
      'video': {
        'width': {'ideal': width},
        'height': {'ideal': height},
        'frameRate': {'ideal': frameRate},
        'cursor': 'always',
        'displaySurface': 'monitor',
        'selfBrowserSurface': 'exclude',
        'surfaceSwitching': 'exclude',
      },
      'audio': false,
    };
  }
}
