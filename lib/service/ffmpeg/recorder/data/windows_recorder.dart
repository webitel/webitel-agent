import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg/manager/manager.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/domain/platform_recorder.dart';

String get _wasapiCapturePath {
  final appDir = p.dirname(Platform.resolvedExecutable);
  return p.join(appDir, 'wasapi_capture.exe');
}

class WindowsRecorder implements PlatformRecorder {
  Process? _videoProcess;
  Process? _captureProcess;
  Process? _audioProcess;

  String? _filePath;
  String? _videoPath;
  String? _audioPath;

  @override
  Future<void> start(String filePath) async {
    final ffmpegPath = await FFmpegManager.instance.path;

    _filePath = filePath;
    _videoPath = '${filePath}_v.mp4';
    _audioPath = '${filePath}_a.aac';

    // Video: gdigrab → temp file. Stdin stays free for 'q' stop signal.
    _videoProcess = await Process.start(
      ffmpegPath,
      [
        '-f', 'gdigrab',
        '-framerate', '15',
        '-i', 'desktop',
        '-vf', 'scale=1280:720',
        '-c:v', 'libx264',
        '-preset', 'ultrafast',
        '-pix_fmt', 'yuv420p',
        '-b:v', '5M',
        '-an',
        '-y',
        _videoPath!,
      ],
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );
    _videoProcess!.stderr
        .transform(const SystemEncoding().decoder)
        .listen(logger.info);

    // Audio: wasapi_capture → FFmpeg (PCM→AAC) → temp file.
    final captureProcess = await Process.start(
      _wasapiCapturePath,
      [],
      runInShell: false,
    );
    _captureProcess = captureProcess;

    captureProcess.stderr
        .transform(const SystemEncoding().decoder)
        .listen((l) => logger.debug('[WasapiCapture/rec] $l'));

    final headerBuf = <int>[];
    bool headerRead = false;
    final audioReady = Completer<Process>();

    captureProcess.stdout.listen(
      (chunk) async {
        if (!headerRead) {
          headerBuf.addAll(chunk);
          if (headerBuf.length < 4) return;

          headerRead = true;
          final sampleRate = headerBuf[0] |
              (headerBuf[1] << 8) |
              (headerBuf[2] << 16) |
              (headerBuf[3] << 24);
          final remainder = Uint8List.fromList(headerBuf.sublist(4));

          final audioProcess = await Process.start(
            ffmpegPath,
            [
              '-f', 's16le',
              '-ar', '$sampleRate',
              '-ac', '2',
              '-i', 'pipe:0',
              '-c:a', 'aac',
              '-b:a', '128k',
              '-y',
              _audioPath!,
            ],
            runInShell: false,
            workingDirectory: p.dirname(ffmpegPath),
          );
          _audioProcess = audioProcess;

          audioProcess.stderr
              .transform(const SystemEncoding().decoder)
              .listen(logger.info);

          audioReady.complete(audioProcess);
          if (remainder.isNotEmpty) audioProcess.stdin.add(remainder);
          return;
        }

        final audioProcess = await audioReady.future;
        audioProcess.stdin.add(chunk);
      },
      onDone: () async {
        if (audioReady.isCompleted) {
          final audioProcess = await audioReady.future;
          await audioProcess.stdin.close().catchError((_) {});
        }
      },
      onError: (e) => logger.error('[WindowsRecorder] PCM pipe error', e),
    );

    logger.info('[WindowsRecorder] Recording started → $filePath');
  }

  @override
  Future<void> stop() async {
    logger.info('[WindowsRecorder] Stopping recording');

    final video = _videoProcess;
    final capture = _captureProcess;
    final audio = _audioProcess;
    _videoProcess = null;
    _captureProcess = null;
    _audioProcess = null;

    // Stop video gracefully via FFmpeg's 'q' command.
    if (video != null) {
      video.stdin.writeln('q');
      await video.stdin.flush().catchError((_) {});
      await video.stdin.close().catchError((_) {});
      await video.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          video.kill();
          return -1;
        },
      );
    }

    // Stop audio chain: closing wasapi_capture stdin signals it to exit,
    // which closes its stdout, which closes the audio FFmpeg's stdin pipe.
    if (capture != null) {
      await capture.stdin.close().catchError((_) {});
      await capture.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          capture.kill();
          return -1;
        },
      );
    }
    if (audio != null) {
      await audio.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          audio.kill();
          return -1;
        },
      );
    }

    await _mux();
  }

  Future<void> _mux() async {
    final videoPath = _videoPath;
    final audioPath = _audioPath;
    final filePath = _filePath;
    if (videoPath == null || audioPath == null || filePath == null) return;

    final ffmpegPath = await FFmpegManager.instance.path;

    logger.info('[WindowsRecorder] Muxing $videoPath + $audioPath → $filePath');

    final mux = await Process.start(
      ffmpegPath,
      [
        '-i', videoPath,
        '-i', audioPath,
        '-c', 'copy',
        '-movflags', '+faststart',
        '-y',
        filePath,
      ],
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );

    mux.stderr
        .transform(const SystemEncoding().decoder)
        .listen(logger.info);

    await mux.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        mux.kill();
        return -1;
      },
    );

    await File(videoPath).delete().catchError((_) => File(videoPath));
    await File(audioPath).delete().catchError((_) => File(audioPath));
  }
}
