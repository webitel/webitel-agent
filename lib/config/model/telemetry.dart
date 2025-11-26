enum TelemetryLevel { debug, info, error, off }

class FileLogConfig {
  final bool enabled;
  final String path;

  FileLogConfig({required this.enabled, required this.path});

  factory FileLogConfig.fromJson(Map<String, dynamic>? json) {
    json ??= {};
    return FileLogConfig(
      enabled: json['enabled'] == true,
      path: json['path'] ?? 'logs/app.log',
    );
  }
}

class OTelConfig {
  final bool enabled;
  final String endpoint;
  final String serviceName;
  final String environment;
  final bool exportLogs;

  OTelConfig({
    required this.enabled,
    required this.endpoint,
    required this.serviceName,
    required this.environment,
    required this.exportLogs,
  });

  factory OTelConfig.fromJson(Map<String, dynamic>? json) {
    json ??= {};
    return OTelConfig(
      enabled: json['enabled'] == true,
      endpoint: json['endpoint'] ?? '',
      serviceName: json['serviceName'] ?? 'app',
      environment: json['environment'] ?? 'prod',
      exportLogs: json['exportLogs'] == true,
    );
  }
}

class TelemetryConfig {
  final TelemetryLevel level;
  final bool console;
  final FileLogConfig file;
  final OTelConfig otel;

  TelemetryConfig({
    required this.level,
    required this.console,
    required this.file,
    required this.otel,
  });

  factory TelemetryConfig.fromJson(Map<String, dynamic>? json) {
    json ??= {};

    TelemetryLevel parseLevel(String? level) {
      switch (level?.toLowerCase()) {
        case 'debug':
          return TelemetryLevel.debug;
        case 'info':
          return TelemetryLevel.info;
        case 'error':
          return TelemetryLevel.error;
        case 'off':
          return TelemetryLevel.off;
        default:
          return TelemetryLevel.info;
      }
    }

    return TelemetryConfig(
      level: parseLevel(json['level'] as String?),
      console: json['console'] == true,
      file: FileLogConfig.fromJson(json['file'] as Map<String, dynamic>?),
      otel: OTelConfig.fromJson(json['opentelemetry'] as Map<String, dynamic>?),
    );
  }
}
