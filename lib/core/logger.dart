import 'dart:async'; // Added for Timer
import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/service/otel/otel_logs.dart';
import '../config/model/config.dart';
import '../config/model/telemetry.dart';

// Global Logger instance
final logger = LoggerService();

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  late Logger _logger;
  IOSink? _fileSink;
  TelemetryConfig? _telemetry;
  OtelLogClient? _otelClient;

  /// Maps the custom TelemetryLevel enum to the standard logger Level enum.
  Level _mapTelemetryLevelToLoggerLevel(TelemetryLevel level) {
    switch (level) {
      case TelemetryLevel.debug:
        return Level.debug;
      case TelemetryLevel.info:
        return Level.info;
      case TelemetryLevel.error:
        return Level.error;
      case TelemetryLevel.off:
        return Level.off;
    }
  }

  /// Initializes the logging service based on the provided application configuration.
  Future<void> init(AppConfigModel? config) async {
    if (config == null) return;

    _telemetry = config.telemetry;

    final level = _mapTelemetryLevelToLoggerLevel(
      _telemetry?.level ?? TelemetryLevel.info,
    );

    _logger = Logger(level: level, printer: CustomPrettyPrinter());

    // FILE LOGGING
    if (_telemetry?.file.enabled == true) {
      final dir = await getApplicationDocumentsDirectory();
      final path = "${dir.path}/${_telemetry!.file.path}";
      final file = File(path);
      // Ensure directory exists and open the file sink in append mode
      await file.create(recursive: true);
      _fileSink = file.openWrite(mode: FileMode.append);
    }

    // OTEL LOGS CLIENT
    if (_telemetry?.otel.enabled == true &&
        _telemetry!.otel.endpoint.isNotEmpty &&
        _telemetry!.otel.exportLogs) {
      _otelClient = OtelLogClient(_telemetry!.otel.endpoint);
    }

    info("LoggerService initialized");
  }

  /// Logs a message at the DEBUG level.
  void debug(String message) => _log("DEBUG", message);

  /// Logs a message at the INFO level.
  void info(String message) => _log("INFO", message);

  /// Logs a message at the WARN level.
  void warn(String message) => _log("WARN", message);

  /// Logs a message at the ERROR level, including error object and stack trace.
  void error(String message, [dynamic err, StackTrace? stack]) {
    final combined = [
      message,
      if (err != null) "Error: $err",
      if (stack != null) stack.toString(),
    ].join("\n");
    _log("ERROR", combined, error: err, stackTrace: stack);
  }

  /// Internal logging method handling console, file, and OpenTelemetry output.
  void _log(
    String level,
    String message, {
    dynamic error,
    StackTrace? stackTrace,
  }) {
    // Console
    if (_telemetry?.console == true) {
      switch (level) {
        case "DEBUG":
          _logger.d(message, error: error, stackTrace: stackTrace);
          break;
        case "INFO":
          _logger.i(message, error: error, stackTrace: stackTrace);
          break;
        case "WARN":
          _logger.w(message, error: error, stackTrace: stackTrace);
          break;
        case "ERROR":
          _logger.e(message, error: error, stackTrace: stackTrace);
          break;
      }
    }

    // File
    if (_fileSink != null) {
      final now = DateTime.now().toIso8601String();
      // Only log the raw message to file, without ANSI colors
      _fileSink!.writeln("[$now][$level] $message");
    }

    // OTEL Logs
    if (_telemetry?.otel.exportLogs == true && _otelClient != null) {
      _otelClient!.exportLog(message, level);
    }
  }

  /// Flushes and closes file resources upon application shutdown.
  Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
  }
}

// ==========================================================
/// Custom LogPrinter for console output with colored metrics logs.
// ==========================================================
/// Custom LogPrinter for console output with colored metrics logs.
class CustomPrettyPrinter extends LogPrinter {
  // ANSI colors for standard log levels
  static final Map<Level, Function> _colors = {
    Level.debug: (String t) => AnsiColor.fg(244)(t), // Light Gray
    Level.info: (String t) => AnsiColor.fg(39)(t), // Light Blue
    Level.warning: (String t) => AnsiColor.fg(226)(t), // Yellow
    Level.error: (String t) => AnsiColor.fg(196)(t), // Red
  };

  // Custom colors and prefixes for WebRTC Metrics logs
  // Default metrics color (Magenta/Purple - ANSI 164)
  static final _defaultMetricsColor = AnsiColor.fg(164);

  // Streaming Metrics (Yellow/Green - ANSI 190)
  static final _streamMetricsColor = AnsiColor.fg(190);
  static const String _streamMetricsPrefix = '[Metrics|STREAM]';

  // Recording Metrics (Bright Cyan/Blue - ANSI 39)
  static final _recordMetricsColor = AnsiColor.fg(39);
  static const String _recordMetricsPrefix = '[Metrics|RECORD]';

  @override
  List<String> log(LogEvent event) {
    // Determine the base color based on the log level
    final baseColor = _colors[event.level] ?? (t) => t;

    final time = _time();
    final level = event.level.name.toUpperCase();
    final message = event.message.toString();

    final sb = StringBuffer();

    // Check if the message is a WebRTC metrics log (only applicable for DEBUG logs)
    if (event.level == Level.debug) {
      Function? colorizer;

      // 1. Check for Recording Metrics
      if (message.startsWith(_recordMetricsPrefix)) {
        colorizer = _recordMetricsColor.call;
        // 2. Check for Streaming Metrics
      } else if (message.startsWith(_streamMetricsPrefix)) {
        colorizer = _streamMetricsColor.call;
        // 3. Check for Default/Old Metrics prefix
      } else if (message.startsWith('[Metrics]')) {
        colorizer = _defaultMetricsColor.call;
      }

      if (colorizer != null) {
        // Apply the custom metrics color to the entire log line
        sb.write(colorizer("[$time][$level] $message"));
      } else {
        // Apply the standard level color
        sb.write(baseColor("[$time][$level] $message"));
      }
    } else {
      // Apply the standard level color for INFO, WARN, ERROR
      sb.write(baseColor("[$time][$level] $message"));
    }

    if (event.error != null) sb.write("\n  ↳ Error: ${event.error}");
    if (event.stackTrace != null) {
      sb.write("\n  ↳ StackTrace: ${event.stackTrace}");
    }

    return [sb.toString()];
  }

  /// Generates a formatted time string (HH:MM:SS).
  String _time() {
    final n = DateTime.now();
    return "${n.hour.toString().padLeft(2, '0')}:"
        "${n.minute.toString().padLeft(2, '0')}:"
        "${n.second.toString().padLeft(2, '0')}";
  }
}
