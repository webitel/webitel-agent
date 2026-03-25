import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/config/model/app.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';

/// Singleton service to manage application configuration.
/// Maintains the "AppConfig" name to preserve compatibility across the project.
class AppConfig {
  static final AppConfig _instance = AppConfig._();
  AppConfig._();

  static AppConfigModel? _cache;

  /// Returns the current configuration instance.
  /// Accessing this before load() will return an empty model with warnings.
  static AppConfigModel get instance {
    if (_cache == null) {
      logger.warn(
        '[AppConfig] Accessing instance before load(). Returning empty defaults.',
      );
      return AppConfigModel.empty();
    }
    return _cache!;
  }

  /// Checks if the config has been successfully initialized in memory.
  static bool get isLoaded => _cache != null;

  /// Loads configuration from the filesystem.
  static Future<AppConfigModel?> load({String? customPath}) async {
    try {
      final file = await _getConfigFile(customPath);

      if (!await file.exists()) {
        logger.warn('[AppConfig] Config file not found at: ${file.path}');
        return null;
      }

      final content = await file.readAsString();
      final Map<String, dynamic> json = jsonDecode(content);

      _cache = AppConfigModel.fromJson(json);
      logger.info('[AppConfig] Configuration successfully loaded.');

      return _cache;
    } catch (e, st) {
      logger.error('[AppConfig] Failed to load or parse configuration', e, st);
      _cache = null;
      return null;
    }
  }

  /// Saves the provided JSON map to the local config file and updates cache.
  static Future<void> save(Map<String, dynamic> json) async {
    try {
      final file = await _getConfigFile(null);

      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      await file.writeAsString(jsonEncode(json), flush: true);
      _cache = AppConfigModel.fromJson(json);

      logger.info('[AppConfig] Configuration saved and synchronized.');
    } catch (e, st) {
      logger.error('[AppConfig] Failed to save configuration', e, st);
      rethrow;
    }
  }

  /// Helper to resolve the correct config file path.
  static Future<File> _getConfigFile(String? customPath) async {
    if (customPath != null) return File(customPath);

    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/config.json');
  }
}
