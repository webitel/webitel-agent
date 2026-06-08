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

    // wasapi_capture writes a 4-byte LE uint32 sample rate before any PCM.
    final headerBuf = <int>[];
    bool headerRead = false;
    final ffmpegReady = Completer<Process>();

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

          final ffmpeg = await Process.start(
            ffmpegPath,
            [
              // Video first — gdigrab wall-clock PTS is the reference timeline.
              // Audio pipe PTS (sample-count based) is rebased to wall-clock via
              // -use_wallclock_as_timestamps so both inputs share the same clock.
              '-f', 'gdigrab',
              '-framerate', '15',
              '-rtbufsize', '100M',
              '-thread_queue_size', '4096',
              '-i', 'desktop',
              '-use_wallclock_as_timestamps', '1',
              '-f', 's16le',
              '-ar', '$sampleRate',
              '-ac', '2',
              '-thread_queue_size', '4096',
              '-i', 'pipe:0',
              // Encoding
              '-vf', 'scale=1280:720',
              '-c:v', 'libx264',
              '-preset', 'ultrafast',
              '-pix_fmt', 'yuv420p',
              '-b:v', '5M',
              '-c:a', 'aac',
              '-b:a', '128k',
              '-async', '1',
              // Stop when audio input closes (wasapi_capture exits on shutdown)
              '-shortest',
              '-movflags', '+faststart',
              '-y',
              filePath,
            ],
            runInShell: false,
            workingDirectory: p.dirname(ffmpegPath),
          );
          _ffmpegProcess = ffmpeg;

          ffmpeg.stderr
              .transform(const SystemEncoding().decoder)
              .listen(logger.info);

          ffmpegReady.complete(ffmpeg);

          if (remainder.isNotEmpty) ffmpeg.stdin.add(remainder);
          return;
        }

        final ffmpeg = await ffmpegReady.future;
        ffmpeg.stdin.add(chunk);
      },
      onDone: () async {
        if (ffmpegReady.isCompleted) {
          final ffmpeg = await ffmpegReady.future;
          await ffmpeg.stdin.close().catchError((_) {});
        }
      },
      onError: (e) => logger.error('[WindowsRecorder] PCM pipe error', e),
    );

    logger.info('[WindowsRecorder] Recording started → $filePath');
  }

  @override
  Future<void> stop() async {
    logger.info('[WindowsRecorder] Stopping recording');

    final capture = _captureProcess;
    final ffmpeg = _ffmpegProcess;
    _captureProcess = null;
    _ffmpegProcess = null;

    // Closing wasapi_capture stdin signals graceful exit; it flushes and
    // closes stdout, which closes FFmpeg's audio pipe, triggering -shortest
    // to finalize the MP4.
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
