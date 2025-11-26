import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/service/otel/otel_logs.dart';
import '../config/model/config.dart';
import '../config/model/telemetry.dart';

final logger = LoggerService();

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  late Logger _logger;
  IOSink? _fileSink;
  TelemetryConfig? _telemetry;
  OtelLogClient? _otelClient;

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

  void debug(String message) => _log("DEBUG", message);
  void info(String message) => _log("INFO", message);
  void warn(String message) => _log("WARN", message);

  void error(String message, [dynamic err, StackTrace? stack]) {
    final combined = [
      message,
      if (err != null) "Error: $err",
      if (stack != null) stack.toString(),
    ].join("\n");
    _log("ERROR", combined, error: err, stackTrace: stack);
  }

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
      _fileSink!.writeln("[$now][$level] $message");
    }

    // OTEL Logs
    if (_telemetry?.otel.exportLogs == true && _otelClient != null) {
      _otelClient!.exportLog(message, level);
    }
  }

  Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
    // _rootSpan?.end();
  }
}

// ==========================================================
class CustomPrettyPrinter extends LogPrinter {
  static final Map<Level, Function> _colors = {
    Level.debug: (String t) => AnsiColor.fg(244)(t),
    Level.info: (String t) => AnsiColor.fg(39)(t),
    Level.warning: (String t) => AnsiColor.fg(226)(t),
    Level.error: (String t) => AnsiColor.fg(196)(t),
  };

  @override
  List<String> log(LogEvent event) {
    final color = _colors[event.level] ?? (t) => t;
    final time = _time();
    final level = event.level.name.toUpperCase();

    final sb = StringBuffer();
    sb.write(color("[$time][$level] ${event.message}"));

    if (event.error != null) sb.write("\n  ↳ Error: ${event.error}");
    if (event.stackTrace != null) {
      sb.write("\n  ↳ StackTrace: ${event.stackTrace}");
    }

    return [sb.toString()];
  }

  String _time() {
    final n = DateTime.now();
    return "${n.hour.toString().padLeft(2, '0')}:"
        "${n.minute.toString().padLeft(2, '0')}:"
        "${n.second.toString().padLeft(2, '0')}";
  }
}
