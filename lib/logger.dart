import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:logger/logger.dart';

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();

  late Logger _logger;
  late Level _level;

  factory LoggerService() => _instance;

  LoggerService._internal() {
    // Read from env, fallback to 'debug' level
    final info = dotenv.env['LOG_LEVEL_INFO']?.toLowerCase() == 'true';
    final debug = dotenv.env['LOG_LEVEL_DEBUG']?.toLowerCase() == 'true';
    final error = dotenv.env['LOG_LEVEL_ERROR']?.toLowerCase() == 'true';

    // Determine minimum log level to output
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
        dateTimeFormat: DateTimeFormat.dateAndTime,
      ),
    );
  }

  void info(String message) {
    _logger.i(message);
  }

  void debug(String message) {
    _logger.d(message);
  }

  void warn(String message) {
    _logger.w(message);
  }

  void error(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }
}
