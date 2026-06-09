import 'telemetry.dart';

class AppConfigModel {
  final String baseUrl;
  final String loginUrl;
  final String webitelWsUrl;

  final int maxCallRecordDuration;

  final TelemetryConfig telemetry;

  final String webrtcSdpUrl;
  final List<Map<String, dynamic>> webrtcIceServers;
  final String webrtcIceTransportPolicy;

  const AppConfigModel({
    required this.baseUrl,
    required this.loginUrl,
    required this.webitelWsUrl,
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
      maxCallRecordDuration: 3600,
      telemetry: TelemetryConfig.fromJson({}),
      webrtcSdpUrl: '',
      webrtcIceServers: const [],
      webrtcIceTransportPolicy: 'all',
    );
  }

  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final server = json['server'] as Map<String, dynamic>? ?? {};
    final video = json['video'] as Map<String, dynamic>? ?? {};
    final webrtc = json['webrtc'] as Map<String, dynamic>? ?? {};

    final baseUrl = server['baseUrl']?.toString() ?? '';

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
        '/ws/websocket?application_name=desc_track',
        isWs: true,
      ),
      maxCallRecordDuration: _toInt(video['maxCallRecordDuration'], 3600),
      telemetry: TelemetryConfig.fromJson(json['telemetry'] ?? {}),
      webrtcSdpUrl: buildUrl('/api/webrtc/video'),
      webrtcIceServers:
          (webrtc['iceServers'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          const [],
      webrtcIceTransportPolicy: webrtc['iceTransportPolicy'] ?? 'all',
    );
  }

  static int _toInt(dynamic v, int def) =>
      int.tryParse(v?.toString() ?? '') ?? def;
}
