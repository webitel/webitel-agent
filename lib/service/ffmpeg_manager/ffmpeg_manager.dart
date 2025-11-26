import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class FFmpegManager {
  FFmpegManager._();
  static final FFmpegManager instance = FFmpegManager._();

  String? _ffmpegPath;

  Future<String> get path async {
    if (_ffmpegPath != null) {
      if (await File(_ffmpegPath!).exists()) {
        return _ffmpegPath!;
      }
    }

    final localDir = await getApplicationSupportDirectory();
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    String assetPath;
    String ffmpegFileName;

    if (Platform.isWindows) {
      assetPath = 'ffmpeg/windows/ffmpeg.exe';
      ffmpegFileName = 'ffmpeg.exe';
    } else if (Platform.isMacOS) {
      assetPath = 'ffmpeg/macos/ffmpeg';
      ffmpegFileName = 'ffmpeg';
    } else {
      throw UnsupportedError('Platform not supported');
    }

    final ffmpegPath = p.join(localDir.path, ffmpegFileName);
    final ffmpegFile = File(ffmpegPath);

    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();

      if (await ffmpegFile.exists()) {
        await ffmpegFile.delete();
      }

      await ffmpegFile.writeAsBytes(bytes, flush: true);

      print('[FFmpegManager] Copied to: $ffmpegPath');
      print('[FFmpegManager] File size: ${await ffmpegFile.length()} bytes');

      if (Platform.isMacOS) {
        await Process.run('chmod', ['+x', ffmpegPath]);
      }
    } catch (e) {
      print('[FFmpegManager] Error copying ffmpeg: $e');
      rethrow;
    }

    if (!await ffmpegFile.exists()) {
      throw Exception('FFmpeg was not copied successfully');
    }

    _ffmpegPath = ffmpegPath;
    return _ffmpegPath!;
  }
}
