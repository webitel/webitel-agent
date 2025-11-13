// lib/config/app_config.dart
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/core/logger.dart';

import 'model/config.dart';

class AppConfig {
  static AppConfigModel? _config;

  static AppConfigModel get instance {
    if (_config == null) {
      logger.warn('AppConfig: Config not loaded, returning empty default.');
      return AppConfigModel.empty();
    }
    return _config!;
  }

  static Future<AppConfigModel?> load({String? customPath}) async {
    try {
      final file = await _resolveConfigFile(customPath);
      final content = await file.readAsString();
      final json = jsonDecode(content);
      _config = AppConfigModel.fromJson(json);
      return _config;
    } catch (e) {
      _config = null;
      return null;
    }
  }

  static Future<File> _resolveConfigFile(String? customPath) async {
    if (customPath != null) {
      final cliFile = File(customPath);
      if (await cliFile.exists()) return cliFile;
    }

    final appSupportDir = await getApplicationSupportDirectory();
    final file = File('${appSupportDir.path}/config.json');
    if (await file.exists()) return file;

    throw Exception('Config file not found');
  }

  static Future<void> save(Map<String, dynamic> json) async {
    final appSupportDir = await getApplicationSupportDirectory();
    final file = File('${appSupportDir.path}/config.json');
    await file.writeAsString(jsonEncode(json), flush: true);
  }
}
