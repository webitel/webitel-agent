class AppConfigModel {
  // --- Base server settings ---
  final String baseUrl;

  // --- Auth ---
  final String loginUrl;

  // --- Media ---
  final bool screenshotEnabled;

  // --- WebSocket connection ---
  final String webitelWsUrl;

  // --- Video configuration ---
  final int videoWidth;
  final int videoHeight;
  final int videoFramerate;
  final bool videoSaveLocally;
  final int maxCallRecordDuration;

  // --- Logger configuration ---
  final bool logInfo;
  final bool logDebug;
  final bool logError;
  final bool logToFile;
  final String logFilePath;

  // --- WebRTC ---
  final String webrtcSdpUrl;
  final List<Map<String, dynamic>> webrtcIceServers;

  AppConfigModel({
    required this.baseUrl,
    required this.loginUrl,
    required this.screenshotEnabled,
    required this.webitelWsUrl,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoFramerate,
    required this.videoSaveLocally,
    required this.maxCallRecordDuration,
    required this.logInfo,
    required this.logDebug,
    required this.logError,
    required this.logToFile,
    required this.logFilePath,
    required this.webrtcSdpUrl,
    required this.webrtcIceServers,
  });

  /// --- Fixed paths (never change) ---
  static const String _loginPath = '/';

  static const String _websocketPath =
      '/ws/websocket?application_name=desc_track&ver=1.0.0';
  static const String _sdpPath = '/api/webrtc/video';

  /// ----------------------------------

  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final server = json['server'] ?? {};
    final baseUrl = server['baseUrl'] ?? '';

    // Helper to combine HTTPS URLs
    String combineUrl(String? path) {
      if (path == null || path.isEmpty) return '';
      if (path.startsWith('http')) return path;
      return '$baseUrl${path.startsWith('/') ? path : '/$path'}';
    }

    // Helper to combine WebSocket URLs (convert http → ws)
    String combineWsUrl(String? path) {
      if (path == null || path.isEmpty) return '';
      if (path.startsWith('ws')) return path;
      final wsBase = baseUrl
          .replaceFirst(RegExp(r'^https'), 'wss')
          .replaceFirst(RegExp(r'^http'), 'ws');
      return '$wsBase${path.startsWith('/') ? path : '/$path'}';
    }

    final media = json['media'] ?? {};
    final logger = json['logger'] ?? {};
    final webrtc = json['webrtc'] ?? {};
    final video = json['video'] ?? {};

    bool parseBool(dynamic v, [bool d = false]) =>
        v is bool ? v : v.toString().toLowerCase() == 'true';

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
      screenshotEnabled: parseBool(media['screenshotEnabled']),
      webitelWsUrl: combineWsUrl(_websocketPath),
      videoWidth: parseInt(video['width'], 1280),
      videoHeight: parseInt(video['height'], 720),
      videoFramerate: parseInt(video['framerate'], 30),
      videoSaveLocally: parseBool(video['saveLocally']),
      maxCallRecordDuration: parseInt(video['maxCallRecordDuration'], 3600),
      logInfo: parseBool(logger['info']),
      logDebug: parseBool(logger['debug']),
      logError: parseBool(logger['error']),
      logToFile: parseBool(logger['toFile']),
      logFilePath: logger['filePath'] ?? '/tmp/log.txt',
      webrtcSdpUrl: combineUrl(_sdpPath),
      webrtcIceServers: parseIceServers(webrtc['iceServers']),
    );
  }
}
