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
  Process? _captureProcess;
  Process? _ffmpegProcess;

  @override
  Future<void> start(String filePath) async {
    final ffmpegPath = await FFmpegManager.instance.path;

    final captureProcess = await Process.start(
      _wasapiCapturePath,
      [],
      runInShell: false,
    );
    _captureProcess = captureProcess;

    captureProcess.stderr
        .transform(const SystemEncoding().decoder)
        .listen((l) => logger.debug('[WasapiCapture/rec] $l'));

    // Read the 4-byte sample-rate header synchronously, buffer everything
    // else in a StreamController, then pipe the controller stream to FFmpeg.
    // Synchronous (non-async) callback avoids concurrent invocations that
    // caused ordering issues with the previous async-listen approach.
    final headerBuf = <int>[];
    bool headerDone = false;
    final sampleRateCompleter = Completer<int>();
    final controller = StreamController<List<int>>();

    captureProcess.stdout.listen(
      (chunk) {
        if (headerDone) {
          controller.add(chunk);
          return;
        }
        headerBuf.addAll(chunk);
        if (headerBuf.length >= 4) {
          headerDone = true;
          final rate = headerBuf[0] |
              (headerBuf[1] << 8) |
              (headerBuf[2] << 16) |
              (headerBuf[3] << 24);
          sampleRateCompleter.complete(rate);
          final remainder = headerBuf.sublist(4);
          if (remainder.isNotEmpty) controller.add(Uint8List.fromList(remainder));
        }
      },
      onDone: () => controller.close(),
      onError: (e) {
        controller.addError(e);
        logger.error('[WindowsRecorder] PCM pipe error', e);
      },
    );

    final sampleRate = await sampleRateCompleter.future;
    logger.info('[WindowsRecorder] wasapi sample rate: $sampleRate');

    final ffmpegProcess = await Process.start(
      ffmpegPath,
      [
        // Video first so gdigrab wall-clock is the reference timeline
        '-f', 'gdigrab', '-framerate', '15', '-i', 'desktop',
        // Audio from wasapi_capture via stdin
        '-f', 's16le', '-ar', '$sampleRate', '-ac', '2', '-i', 'pipe:0',
        '-vf', 'scale=1280:720',
        '-c:v', 'libx264', '-preset', 'ultrafast',
        '-pix_fmt', 'yuv420p', '-b:v', '5M',
        '-c:a', 'aac', '-b:a', '128k',
        '-shortest',
        '-movflags', '+faststart',
        '-y', filePath,
      ],
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );
    _ffmpegProcess = ffmpegProcess;

    ffmpegProcess.stderr
        .transform(const SystemEncoding().decoder)
        .listen(logger.info);

    // pipe() handles backpressure and closes ffmpegProcess.stdin when done
    controller.stream.pipe(ffmpegProcess.stdin).catchError(
      (e) => logger.error('[WindowsRecorder] pipe error', e),
    );

    logger.info('[WindowsRecorder] Recording started → $filePath');
  }

  @override
  Future<void> stop() async {
    if (_captureProcess == null) return;
    logger.info('[WindowsRecorder] Stopping recording');

    final capture = _captureProcess;
    final ffmpeg = _ffmpegProcess;
    _captureProcess = null;
    _ffmpegProcess = null;

    // Closing wasapi_capture stdin signals it to exit; stdout closes → pipe()
    // closes ffmpegProcess.stdin → -shortest finalizes the MP4.
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

    if (ffmpeg != null) {
      await ffmpeg.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          ffmpeg.kill();
          return -1;
        },
      );
    }
  }
}
