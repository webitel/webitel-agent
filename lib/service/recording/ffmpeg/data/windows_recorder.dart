import 'dart:io';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg_manager/ffmpeg_manager.dart';
import 'package:path/path.dart' as p;
import 'package:webitel_desk_track/service/recording/ffmpeg/domain/platform_recorder.dart';

class WindowsRecorder implements PlatformRecorder {
  Process? _process;

  @override
  Future<void> start(String filePath) async {
    final ffmpegPath = await FFmpegManager.instance.path;

    _process = await Process.start(
      ffmpegPath,
      [
        '-f', 'gdigrab', // Windows screen grabber
        '-framerate', '15',
        '-i', 'desktop',
        '-vf', 'scale=1280:720',
        '-c:v', 'libx264',
        '-preset', 'ultrafast',
        '-pix_fmt', 'yuv420p',
        '-b:v', '5M',
        '-movflags', '+faststart',
        '-y',
        filePath,
      ],
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );

    logger.info('Windows recording started → $filePath');
    _process!.stderr.transform(SystemEncoding().decoder).listen(logger.info);
  }

  @override
  Future<void> stop() async {
    if (_process == null) return;
    logger.info('Stopping Windows FFmpeg');

    _process!.stdin.writeln('q');
    await _process!.stdin.flush();
    await _process!.stdin.close();

    await _process!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        logger.warn('FFmpeg did not exit → killing...');
        _process!.kill();
        return -1;
      },
    );

    _process = null;
  }
}
