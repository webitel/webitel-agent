import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/config/model/app.dart';
import '../../config/model/telemetry.dart';

/// Global access point for logging
final logger = LoggerService.instance;

class LoggerService {
  static final LoggerService instance = LoggerService._internal();
  LoggerService._internal();

  // Initialize with a dummy logger to prevent LateInitializationError
  Logger _logger = Logger(printer: PrettyPrinter(), level: Level.off);

  IOSink? _fileSink;
  TelemetryConfig? _telemetry;
  // Placeholder for OtelClient if needed
  // OtelLogClient? _otelClient;

  /// Initializes the logger with app configuration
  Future<void> init(AppConfigModel? config) async {
    if (config == null) return;
    _telemetry = config.telemetry;

    final logLevel = _mapLevel(_telemetry?.level ?? TelemetryLevel.info);

    // Re-initialize the main logger with proper settings
    _logger = Logger(
      level: logLevel,
      printer: CustomPrettyPrinter(),
      // We disable default console output because we handle it manually in _log
      output: ConsoleOutput(),
    );

    // Initialize File logging
    if (_telemetry?.file.enabled == true) {
      await _initFileLogging(_telemetry!.file.path);
    }

    info("[Logger] Initialized with level: ${logLevel.name.toUpperCase()}");
  }

  Future<void> _initFileLogging(String relativePath) async {
    try {
      final dir =
          await getApplicationSupportDirectory(); // Better for logs than Documents
      final file = File("${dir.path}/$relativePath");

      await file.create(recursive: true);
      _fileSink = file.openWrite(mode: FileMode.append);

      // Add a separator for new sessions
      _fileSink?.writeln(
        "\n--- NEW SESSION: ${DateTime.now().toIso8601String()} ---",
      );
    } catch (e) {
      // Fallback to standard print if file logging fails
      if (kDebugMode) {
        print("Failed to initialize file logger: $e");
      }
    }
  }

  Level _mapLevel(TelemetryLevel level) {
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

  // --- Public API ---

  void debug(String msg) => _log(Level.debug, msg);
  void info(String msg) => _log(Level.info, msg);
  void warn(String msg) => _log(Level.warning, msg);

  void error(String msg, [dynamic err, StackTrace? stack]) {
    _log(Level.error, msg, error: err, stackTrace: stack);
  }

  // --- Internal Processing ---

  void _log(
    Level level,
    String message, {
    dynamic error,
    StackTrace? stackTrace,
  }) {
    // 1. Console Output (controlled by telemetry config)
    if (_telemetry?.console == true || _telemetry == null) {
      _logger.log(level, message, error: error, stackTrace: stackTrace);
    }

    // 2. File Output
    if (_fileSink != null) {
      final now = DateTime.now().toIso8601String().substring(
        11,
        19,
      ); // HH:mm:ss
      final logLine = "[$now][${level.name.toUpperCase()}] $message";

      _fileSink!.writeln(logLine);
      if (error != null) _fileSink!.writeln("  ↳ Error: $error");
    }

    // 3. OpenTelemetry Export
    if (_telemetry?.otel.exportLogs == true) {
      // _otelClient?.export(message, level.name);
    }
  }

  Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
    _logger.close();
  }
}

/// Custom printer for professional console output
class CustomPrettyPrinter extends LogPrinter {
  // ANSI colors (simplified)
  static final _debugColor = AnsiColor.fg(244);
  static final _infoColor = AnsiColor.fg(39);
  static final _warnColor = AnsiColor.fg(226);
  static final _errColor = AnsiColor.fg(196);
  static final _metricsColor = AnsiColor.fg(164);

  @override
  List<String> log(LogEvent event) {
    final time = _formatTime(event.time);
    final level = event.level.name.toUpperCase().padRight(5);
    final msg = event.message.toString();

    AnsiColor color;

    // Logic for WebRTC Metrics coloring
    if (msg.contains('[Metrics')) {
      color = _metricsColor;
    } else {
      switch (event.level) {
        case Level.debug:
          color = _debugColor;
          break;
        case Level.info:
          color = _infoColor;
          break;
        case Level.warning:
          color = _warnColor;
          break;
        case Level.error:
          color = _errColor;
          break;
        default:
          color = AnsiColor.none();
      }
    }

    final output = color("[$time] [$level] $msg");

    final result = [output];
    if (event.error != null) result.add(color("  ↳ Error: ${event.error}"));
    if (event.stackTrace != null) {
      result.add(color("  ↳ Stack: ${event.stackTrace}"));
    }

    return result;
  }

  String _formatTime(DateTime time) {
    return "${time.hour.toString().padLeft(2, '0')}:"
        "${time.minute.toString().padLeft(2, '0')}:"
        "${time.second.toString().padLeft(2, '0')}";
  }
}
