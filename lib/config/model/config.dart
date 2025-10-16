class AppConfigModel {
  // Base server URL
  final String baseUrl;

  // Auth
  final String loginUrl;

  // Media
  final bool screenshotEnabled;
  final String mediaUploadUrl;

  // WebSocket / connection
  final String webitelWsUrl;

  // Video
  final int videoWidth;
  final int videoHeight;
  final int videoFramerate;
  final bool videoSaveLocally;

  // Logger
  final bool logInfo;
  final bool logDebug;
  final bool logError;
  final bool logToFile;
  final String logFilePath;

  // WebRTC
  final String webrtcSdpUrl;
  final List<Map<String, dynamic>> webrtcIceServers;

  AppConfigModel({
    required this.baseUrl,
    required this.loginUrl,
    required this.screenshotEnabled,
    required this.mediaUploadUrl,
    required this.webitelWsUrl,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoFramerate,
    required this.videoSaveLocally,
    required this.logInfo,
    required this.logDebug,
    required this.logError,
    required this.logToFile,
    required this.logFilePath,
    required this.webrtcSdpUrl,
    required this.webrtcIceServers,
  });

  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    final server = json['server'] ?? {};
    final baseUrl = server['baseUrl'] ?? '';

    String combineUrl(String? path) {
      if (path == null || path.isEmpty) return '';
      if (path.startsWith('http')) return path; // already full URL
      return '$baseUrl${path.startsWith('/') ? path : '/$path'}';
    }

    final auth = json['auth'] ?? {};
    final media = json['media'] ?? {};
    final connection = json['connection'] ?? {};
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
      loginUrl: combineUrl(auth['loginPath']),
      screenshotEnabled: parseBool(media['screenshotEnabled']),
      mediaUploadUrl: combineUrl(media['uploadPath']),
      webitelWsUrl: combineUrl(connection['websocketPath']),
      videoWidth: parseInt(video['width'], 1280),
      videoHeight: parseInt(video['height'], 720),
      videoFramerate: parseInt(video['framerate'], 30),
      videoSaveLocally: parseBool(video['saveLocally']),
      logInfo: parseBool(logger['info']),
      logDebug: parseBool(logger['debug']),
      logError: parseBool(logger['error']),
      logToFile: parseBool(logger['toFile']),
      logFilePath: logger['filePath'] ?? '/tmp/log.txt',
      webrtcSdpUrl: combineUrl(webrtc['sdpPath']),
      webrtcIceServers: parseIceServers(webrtc['iceServers']),
    );
  }
}
