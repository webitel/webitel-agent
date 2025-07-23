// lib/config/model/app_config_model.dart


class AppConfigModel {
  final String loginUrl;
  final bool screenshotEnabled;
  final String mediaUploadUrl;
  final String webitelWsUrl;

  // Logger
  final bool logLevelInfo;
  final bool logLevelDebug;
  final bool logLevelError;
  final bool logToFile;
  final String logFilePath;

  // WebRTC
  final String webrtcSdpUrl;
  final List<Map<String, dynamic>> webrtcIceServers;

  // Screen Capture
  final int videoWidth;
  final int videoHeight;
  final int videoFramerate;

  AppConfigModel({
    required this.loginUrl,
    required this.screenshotEnabled,
    required this.mediaUploadUrl,
    required this.webitelWsUrl,
    required this.logLevelInfo,
    required this.logLevelDebug,
    required this.logLevelError,
    required this.logToFile,
    required this.logFilePath,
    required this.webrtcSdpUrl,
    required this.webrtcIceServers,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoFramerate,
  });

  factory AppConfigModel.fromJson(Map<String, dynamic> json) {
    return AppConfigModel(
      loginUrl: json['LOGIN_URL'] ?? '',
      screenshotEnabled:
          (json['SCREENSHOT_ENABLED'] ?? 'false').toString().toLowerCase() ==
          'true',
      mediaUploadUrl: json['MEDIA_UPLOAD_URL'] ?? '',
      webitelWsUrl: json['WEBITEL_WS_URL'] ?? '',

      logLevelInfo:
          (json['LOG_LEVEL_INFO'] ?? 'false').toString().toLowerCase() ==
          'true',
      logLevelDebug:
          (json['LOG_LEVEL_DEBUG'] ?? 'false').toString().toLowerCase() ==
          'true',
      logLevelError:
          (json['LOG_LEVEL_ERROR'] ?? 'false').toString().toLowerCase() ==
          'true',
      logToFile:
          (json['LOG_TO_FILE'] ?? 'false').toString().toLowerCase() == 'true',
      logFilePath: json['LOG_FILE_PATH'] ?? '',

      webrtcSdpUrl: json['WEBRTC_SDP_URL'] ?? '',
      webrtcIceServers:
          (json['WEBRTC_ICE_SERVERS'] as List<dynamic>? ?? [])
              .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
              .toList(),

      videoWidth: int.tryParse(json['VIDEO_WIDTH']?.toString() ?? '') ?? 1280,
      videoHeight: int.tryParse(json['VIDEO_HEIGHT']?.toString() ?? '') ?? 720,
      videoFramerate:
          int.tryParse(json['VIDEO_FRAMERATE']?.toString() ?? '') ?? 30,
    );
  }

  /// Returns default logger levels as a map
  static AppConfigModel defaultLogger() {
    return AppConfigModel(
      loginUrl: '',
      screenshotEnabled: false,
      mediaUploadUrl: '',
      webitelWsUrl: '',
      logLevelInfo: true,
      logLevelDebug: true,
      logLevelError: true,
      logToFile: true,
      logFilePath: '/tmp/log.txt',
      webrtcSdpUrl: '',
      webrtcIceServers: [],
      videoWidth: 640,
      videoHeight: 480,
      videoFramerate: 30,
    );
  }
}
