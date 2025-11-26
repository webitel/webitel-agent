import 'package:webitel_desk_track/config/model/telemetry.dart';

class AppConfigModel {
  // --- Base server settings ---
  final String baseUrl;
  final String loginUrl;
  final String webitelWsUrl;

  // --- Video configuration ---
  final int videoWidth;
  final int videoHeight;
  final bool videoSaveLocally;
  final int maxCallRecordDuration;

  // --- Telemetry (unified logger + otel) ---
  final TelemetryConfig telemetry;

  // --- WebRTC ---
  final String webrtcSdpUrl;
  final List<Map<String, dynamic>> webrtcIceServers;
  final String webrtcIceTransportPolicy;

  AppConfigModel({
    required this.baseUrl,
    required this.loginUrl,
    required this.webitelWsUrl,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoSaveLocally,
    required this.maxCallRecordDuration,
    required this.telemetry,
    required this.webrtcSdpUrl,
    required this.webrtcIceServers,
    required this.webrtcIceTransportPolicy,
  });

  factory AppConfigModel.empty() {
    return AppConfigModel(
      baseUrl: '',
      loginUrl: '',
      webitelWsUrl: '',
      videoWidth: 1280,
      videoHeight: 720,
      videoSaveLocally: false,
      maxCallRecordDuration: 3600,
      telemetry: TelemetryConfig.fromJson({}),
      webrtcSdpUrl: '',
      webrtcIceServers: const [],
      webrtcIceTransportPolicy: 'all',
    );
  }

  /// --- Fixed paths ---
  static const String _loginPath = '/';
  static const String _websocketPath =
      '/ws/websocket?application_name=desc_track&ver=1.0.0';
  static const String _sdpPath = '/api/webrtc/video';

  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final server = json['server'] ?? {};
    final baseUrl = server['baseUrl'] ?? '';

    // Combine URLs
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

    final telemetryJson = json['telemetry'] ?? {};
    final webrtc = json['webrtc'] ?? {};
    final video = json['video'] ?? {};

    int parseInt(dynamic v, [int d = 0]) =>
        int.tryParse(v?.toString() ?? '') ?? d;

    List<Map<String, dynamic>> parseIceServers(dynamic v) {
      if (v is List) {
        return v.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      return [];
    }

    return AppConfigModel(
      baseUrl: baseUrl,
      loginUrl: combineUrl(_loginPath),
      webitelWsUrl: combineWsUrl(_websocketPath),

      /// ---- video ----
      videoWidth: parseInt(video['width'], 1280),
      videoHeight: parseInt(video['height'], 720),
      videoSaveLocally: video['saveLocally'] == true,
      maxCallRecordDuration: parseInt(video['maxCallRecordDuration'], 3600),

      /// ---- telemetry ----
      telemetry: TelemetryConfig.fromJson(telemetryJson),

      /// ---- webrtc ----
      webrtcSdpUrl: combineUrl(_sdpPath),
      webrtcIceServers: parseIceServers(webrtc['iceServers']),
      webrtcIceTransportPolicy: webrtc['iceTransportPolicy'] ?? 'all',
    );
  }
}
