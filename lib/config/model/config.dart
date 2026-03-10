import 'package:webitel_desk_track/config/model/telemetry.dart';

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
  final bool webrtcEnableMetrics;

  final List<String> stereoMixKeywords;
  final List<String> microphoneKeywords;

  AppConfigModel({
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
    required this.webrtcEnableMetrics,
    required this.stereoMixKeywords,
    required this.microphoneKeywords,
  });

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
      webrtcEnableMetrics: false,
      stereoMixKeywords: const ['Stereo Mix'],
      microphoneKeywords: const ['Microphone'],
    );
  }

  static const String _loginPath = '/';
  static const String _websocketPath =
      '/ws/websocket?application_name=desc_track&ver=1.0.0';
  static const String _sdpPath = '/api/webrtc/video';

  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final server = json['server'] ?? {};
    final baseUrl = server['baseUrl'] ?? '';
    final devices = json['devices'] ?? {};

    String combineUrl(String? path) {
      if (path == null || path.isEmpty) return '';
      if (path.startsWith('http')) return path;
      return '$baseUrl${path.startsWith('/') ? path : '/$path'}';
    }

    String combineWsUrl(String? path) {
      if (path == null || path.isEmpty) return '';
      if (path.startsWith('ws')) return path;
      final wsBase = baseUrl
          .replaceFirst(RegExp(r'^https'), 'wss')
          .replaceFirst(RegExp(r'^http'), 'ws');
      return '$wsBase${path.startsWith('/') ? path : '/$path'}';
    }

    int parseInt(dynamic v, [int d = 0]) =>
        int.tryParse(v?.toString() ?? '') ?? d;

    List<String> parseStrings(dynamic v, List<String> def) {
      if (v is List) return v.map((e) => e.toString()).toList();
      return def;
    }

    return AppConfigModel(
      baseUrl: baseUrl,
      loginUrl: combineUrl(_loginPath),
      webitelWsUrl: combineWsUrl(_websocketPath),
      videoWidth: parseInt(json['video']?['width'], 1280),
      videoHeight: parseInt(json['video']?['height'], 720),
      framerate: parseInt(json['video']?['framerate'], 30),
      videoSaveLocally: json['video']?['saveLocally'] == true,
      maxCallRecordDuration: parseInt(
        json['video']?['maxCallRecordDuration'],
        3600,
      ),
      telemetry: TelemetryConfig.fromJson(json['telemetry'] ?? {}),
      webrtcSdpUrl: combineUrl(_sdpPath),
      webrtcIceServers:
          (json['webrtc']?['iceServers'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          [],
      webrtcIceTransportPolicy: json['webrtc']?['iceTransportPolicy'] ?? 'all',
      webrtcEnableMetrics: json['webrtc']?['enableMetrics'] == true,
      stereoMixKeywords: parseStrings(devices['stereoMixKeywords'], [
        'Stereo Mix',
      ]),
      microphoneKeywords: parseStrings(devices['microphoneKeywords'], [
        'Microphone',
      ]),
    );
  }
}
