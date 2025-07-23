import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import 'config/model/config.dart';

final logger = LoggerService();

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();

  late Logger _logger;
  late Level _level;
  IOSink? _fileSink;

  factory LoggerService() => _instance;

  LoggerService._internal();

  Future<void> init(AppConfigModel? config) async {
    final bool logLevelDebug = config?.logLevelDebug ?? false;
    final bool logLevelInfo = config?.logLevelInfo ?? false;
    final bool logLevelError = config?.logLevelError ?? true;
    final bool logToFile = config?.logToFile ?? false;
    final String logFilePath = config?.logFilePath ?? '';

    if (logLevelDebug) {
      _level = Level.debug;
    } else if (logLevelInfo) {
      _level = Level.info;
    } else if (logLevelError) {
      _level = Level.error;
    } else {
      _level = Level.nothing;
    }

    _logger = Logger(
      level: _level,
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 5,
        lineLength: 80,
        colors: true,
        printEmojis: true,
        printTime: true,
      ),
    );

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
    _logToFile('ERROR', '$message\n$error\n${stackTrace ?? ''}');
  }

  Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
  }
}
