import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg/manager/manager.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/domain/platform_recorder.dart';

class WindowsRecorder implements PlatformRecorder {
  Process? _process;

  @override
  Future<void> start(String filePath) async {
    final ffmpegPath = await FFmpegManager.instance.path;

    _process = await Process.start(
      ffmpegPath,
      [
        // Loopback — system audio (client voice from speakers)
        '-f', 'wasapi', '-loopback', '1', '-i', 'default',
        // Microphone — operator voice
        '-f', 'wasapi', '-i', 'default',
        // Screen
        '-f', 'gdigrab', '-framerate', '15', '-i', 'desktop',
        // Mix loopback at reduced gain into mic
        '-filter_complex', '[0:a]volume=0.15[lb];[lb][1:a]amix=inputs=2:normalize=0[a]',
        '-map', '2:v',
        '-map', '[a]',
        '-vf', 'scale=1280:720',
        '-c:v', 'libx264', '-preset', 'ultrafast',
        '-pix_fmt', 'yuv420p', '-b:v', '5M',
        '-c:a', 'aac', '-b:a', '128k',
        '-movflags', '+faststart',
        '-y', filePath,
      ],
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );

    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .listen(logger.info);

    logger.info('[WindowsRecorder] Recording started → $filePath');
  }

  @override
  Future<void> stop() async {
    if (_process == null) return;
    logger.info('[WindowsRecorder] Stopping recording');

    _process!.stdin.writeln('q');
    await _process!.stdin.flush().catchError((_) {});
    await _process!.stdin.close().catchError((_) {});

    await _process!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process?.kill();
        return -1;
      },
    );

    _process = null;
  }
}
