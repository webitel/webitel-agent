enum TelemetryLevel { debug, info, error, off }

class TelemetryConfig {
  final TelemetryLevel level;
  final bool console;
  final FileLogConfig file;
  final OTelConfig otel;

  const TelemetryConfig({
    required this.level,
    required this.console,
    required this.file,
    required this.otel,
  });

  factory TelemetryConfig.fromJson(Map<String, dynamic> json) {
    return TelemetryConfig(
      level: _parseLevel(json['level']),
      console: json['console'] == true,
      file: FileLogConfig.fromJson(json['file'] ?? {}),
      otel: OTelConfig.fromJson(json['opentelemetry'] ?? {}),
    );
  }

  static TelemetryLevel _parseLevel(dynamic level) {
    switch (level?.toString().toLowerCase()) {
      case 'debug':
        return TelemetryLevel.debug;
      case 'error':
        return TelemetryLevel.error;
      case 'off':
        return TelemetryLevel.off;
      default:
        return TelemetryLevel.info;
    }
  }
}

class FileLogConfig {
  final bool enabled;
  final String path;

  const FileLogConfig({required this.enabled, required this.path});

  factory FileLogConfig.fromJson(Map<String, dynamic> json) {
    return FileLogConfig(
      enabled: json['enabled'] == true,
      path: json['path'] ?? 'logs/app.log',
    );
  }
}

class OTelConfig {
  final String endpoint;
  final String serviceName;
  final String environment;
  final bool exportLogs;

  const OTelConfig({
    required this.endpoint,
    required this.serviceName,
    required this.environment,
    required this.exportLogs,
  });

  factory OTelConfig.fromJson(Map<String, dynamic> json) {
    return OTelConfig(
      endpoint: json['endpoint'] ?? '',
      serviceName: json['serviceName'] ?? 'webitel-desk-track',
      environment: json['environment'] ?? 'production',
      exportLogs: json['exportLogs'] == true,
    );
  }
}
