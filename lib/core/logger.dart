import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import '../config/model/config.dart';

final logger = LoggerService();

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  late Logger _logger;
  late Level _level;
  IOSink? _fileSink;

  factory LoggerService() => _instance;
  LoggerService._internal();

  Future<void> init(AppConfigModel? config) async {
    final bool logLevelDebug = config?.logDebug ?? false;
    final bool logLevelInfo = config?.logInfo ?? false;
    final bool logLevelError = config?.logError ?? true;
    final bool logToFile = config?.logToFile ?? false;
    final String logFilePath = config?.logFilePath ?? '';

    if (logLevelDebug) {
      _level = Level.debug;
    } else if (logLevelInfo) {
      _level = Level.info;
    } else if (logLevelError) {
      _level = Level.error;
    } else {
      _level = Level.off;
    }

    _logger = Logger(level: _level, printer: CustomPrettyPrinter());

    if (logToFile) {
      final dir = await getApplicationDocumentsDirectory();
      final filePath =
          logFilePath.isNotEmpty
              ? '${dir.path}/$logFilePath'
              : '${dir.path}/app.log';

      final logFile = File(filePath);
      await logFile.create(recursive: true);
      _fileSink = logFile.openWrite(mode: FileMode.append);
    }
  }

  void _logToFile(String level, String message) {
    if (_fileSink != null) {
      final now = DateTime.now().toIso8601String();
      _fileSink!.writeln('[$now][$level] $message');
    }
  }

  void info(String message) {
    _logger.i(message);
    _logToFile('INFO', message);
  }

  void debug(String message) {
    _logger.d(message);
    _logToFile('DEBUG', message);
  }

  void warn(String message) {
    _logger.w(message);
    _logToFile('WARN', message);
  }

  void error(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);

    final errorText = error != null ? error.toString() : '';
    final stackText = stackTrace != null ? stackTrace.toString() : '';

    _logToFile(
      'ERROR',
      [message, errorText, stackText].where((s) => s.isNotEmpty).join('\n'),
    );
  }

  Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
  }
}

class CustomPrettyPrinter extends LogPrinter {
  static final levelColors = {
    Level.debug: (String text) => AnsiColor.fg(AnsiColor.grey(0.6))(text),
    Level.info: (String text) => AnsiColor.fg(39)(text),
    Level.warning: (String text) => AnsiColor.fg(226)(text),
    Level.error: (String text) => AnsiColor.fg(196)(text),
    Level.off: (String text) => AnsiColor.fg(201)(text),
  };

  @override
  List<String> log(LogEvent event) {
    final colorize = levelColors[event.level] ?? (String text) => text;
    final time = _formattedTime();
    final level = event.level.toString().split('.').last.toUpperCase();

    final buffer = StringBuffer();
    buffer.write(colorize('[$time] [$level] ${event.message}'));

    if (event.error != null) {
      buffer.writeln(colorize('\n  ↳ Error: ${event.error}'));
    }

    if (event.stackTrace != null) {
      buffer.writeln(colorize('  ↳ StackTrace: ${event.stackTrace}'));
    }

    return [buffer.toString()];
  }

  String _formattedTime() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
