import 'telemetry.dart';

class AppConfigModel {
  final String baseUrl;
  final String loginUrl;
  final String webitelWsUrl;

  final int videoWidth;
  final int videoHeight;
  final int framerate;
  final bool videoSaveLocally;
  final int maxCallRecordDuration;

  final TelemetryConfig telemetry;

  final String webrtcSdpUrl;
  final List<Map<String, dynamic>> webrtcIceServers;
  final String webrtcIceTransportPolicy;

  final List<String> stereoMixKeywords;
  final List<String> microphoneKeywords;

  const AppConfigModel({
    required this.baseUrl,
    required this.loginUrl,
    required this.webitelWsUrl,
    required this.videoWidth,
    required this.videoHeight,
    required this.framerate,
    required this.videoSaveLocally,
    required this.maxCallRecordDuration,
    required this.telemetry,
    required this.webrtcSdpUrl,
    required this.webrtcIceServers,
    required this.webrtcIceTransportPolicy,
    required this.stereoMixKeywords,
    required this.microphoneKeywords,
  });

  /// Creates a safe fallback configuration
  factory AppConfigModel.empty() {
    return AppConfigModel(
      baseUrl: '',
      loginUrl: '',
      webitelWsUrl: '',
      videoWidth: 1280,
      videoHeight: 720,
      framerate: 30,
      videoSaveLocally: false,
      maxCallRecordDuration: 3600,
      telemetry: TelemetryConfig.fromJson({}),
      webrtcSdpUrl: '',
      webrtcIceServers: const [],
      webrtcIceTransportPolicy: 'all',
      stereoMixKeywords: const ['Stereo Mix'],
      microphoneKeywords: const ['Microphone'],
    );
  }

  /// Main mapping logic from JSON to Model
  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final server = json['server'] as Map<String, dynamic>? ?? {};
    final video = json['video'] as Map<String, dynamic>? ?? {};
    final webrtc = json['webrtc'] as Map<String, dynamic>? ?? {};
    final devices = json['devices'] as Map<String, dynamic>? ?? {};

    final baseUrl = server['baseUrl']?.toString() ?? '';

    // Internal helper for URL validation and assembly
    String buildUrl(String path, {bool isWs = false}) {
      if (baseUrl.isEmpty) return '';
      if (path.startsWith('http') || path.startsWith('ws')) return path;

      var finalBase = baseUrl;
      if (isWs) {
        finalBase = finalBase
            .replaceFirst('https://', 'wss://')
            .replaceFirst('http://', 'ws://');
      }

      final normalizedPath = path.startsWith('/') ? path : '/$path';
      return '$finalBase$normalizedPath';
    }

    return AppConfigModel(
      baseUrl: baseUrl,
      loginUrl: buildUrl('/'),
      webitelWsUrl: buildUrl(
        '/ws/websocket?application_name=desk_track',
        isWs: true,
      ),
      videoWidth: _toInt(video['width'], 1280),
      videoHeight: _toInt(video['height'], 720),
      framerate: _toInt(video['framerate'], 30),
      videoSaveLocally: video['saveLocally'] == true,
      maxCallRecordDuration: _toInt(video['maxCallRecordDuration'], 3600),
      telemetry: TelemetryConfig.fromJson(json['telemetry'] ?? {}),
      webrtcSdpUrl: buildUrl('/api/webrtc/video'),
      webrtcIceServers:
          (webrtc['iceServers'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          const [],
      webrtcIceTransportPolicy: webrtc['iceTransportPolicy'] ?? 'all',
      stereoMixKeywords: _toStringList(devices['stereoMixKeywords'], [
        'Stereo Mix',
      ]),
      microphoneKeywords: _toStringList(devices['microphoneKeywords'], [
        'Microphone',
      ]),
    );
  }

  static int _toInt(dynamic v, int def) =>
      int.tryParse(v?.toString() ?? '') ?? def;

  static List<String> _toStringList(dynamic v, List<String> def) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return def;
  }
}
