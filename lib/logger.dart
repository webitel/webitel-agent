import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();

  late Logger _logger;
  late Level _level;
  IOSink? _fileSink;

  factory LoggerService() => _instance;

  LoggerService._internal() {
    final info = dotenv.env['LOG_LEVEL_INFO']?.toLowerCase() == 'true';
    final debug = dotenv.env['LOG_LEVEL_DEBUG']?.toLowerCase() == 'true';
    final error = dotenv.env['LOG_LEVEL_ERROR']?.toLowerCase() == 'true';

    if (debug) {
      _level = Level.debug;
    } else if (info) {
      _level = Level.info;
    } else if (error) {
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

    _initFileLogging();
  }

  Future<void> _initFileLogging() async {
    final logToFile = dotenv.env['LOG_TO_FILE']?.toLowerCase() == 'true';
    if (!logToFile) return;

    final customPath = dotenv.env['LOG_FILE_PATH'];
    final dir = await getApplicationDocumentsDirectory();
    final filePath = customPath != null && customPath.isNotEmpty
        ? '${dir.path}/$customPath'
        : '${dir.path}/app.log';

    final logFile = File(filePath);
    await logFile.create(recursive: true);
    _fileSink = logFile.openWrite(mode: FileMode.append);
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
