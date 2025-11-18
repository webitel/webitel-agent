import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FFmpegManager {
  FFmpegManager._();
  static final FFmpegManager instance = FFmpegManager._();

  String? _ffmpegPath;

  Future<String> get path async {
    if (_ffmpegPath != null) return _ffmpegPath!;

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

    if (!await File(ffmpegPath).exists()) {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      await File(ffmpegPath).writeAsBytes(bytes, flush: true);

      if (Platform.isMacOS) {
        await Process.run('chmod', ['+x', ffmpegPath]);
      }
    }

    _ffmpegPath = ffmpegPath;
    return _ffmpegPath!;
  }
}
