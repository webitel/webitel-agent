import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';

class FFmpegManager {
  FFmpegManager._();
  static final FFmpegManager instance = FFmpegManager._();

  String? _ffmpegPath;

  /// Initializes the FFmpeg binary.
  /// Should be called during app startup to ensure the binary is ready.
  Future<void> init() async {
    try {
      _ffmpegPath = await _prepareFFmpeg();
      logger.info(
        '[FFmpegManager] Initialization complete. Path: $_ffmpegPath',
      );
    } catch (e) {
      logger.error('[FFmpegManager] Init failed: $e');
    }
  }

  /// Returns the cached path or triggers preparation if not initialized.
  Future<String> get path async {
    if (_ffmpegPath != null) return _ffmpegPath!;
    return await _prepareFFmpeg();
  }

  /// Internal logic to copy binary from assets to local storage.
  Future<String> _prepareFFmpeg() async {
    final localDir = await getApplicationSupportDirectory();
    final String ffmpegFileName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final String ffmpegPath = p.join(localDir.path, ffmpegFileName);
    final File ffmpegFile = File(ffmpegPath);

    // Optimization: Return immediately if the binary already exists locally.
    if (await ffmpegFile.exists()) {
      return ffmpegPath;
    }

    // Ensure the application support directory exists.
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    // Determine asset path based on current OS.
    // Note: Ensure these paths match your pubspec.yaml exactly.
    String assetPath =
        Platform.isWindows
            ? 'assets/ffmpeg/windows/ffmpeg.exe'
            : 'assets/bin/macos/ffmpeg';

    try {
      logger.info('[FFmpegManager] Copying binary from assets: $assetPath');

      // Load binary data from Flutter assets.
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();

      // Write bytes to the local file system.
      await ffmpegFile.writeAsBytes(bytes, flush: true);

      // On macOS, we must explicitly grant execution permissions.
      if (Platform.isMacOS) {
        await Process.run('chmod', ['+x', ffmpegPath]);
      }

      return ffmpegPath;
    } catch (e) {
      logger.error('[FFmpegManager] Failed to copy FFmpeg binary: $e');
      rethrow;
    }
  }
}
