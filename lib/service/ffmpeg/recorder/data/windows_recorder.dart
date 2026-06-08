import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg/manager/manager.dart';
import 'package:path/path.dart' as p;
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
    final pipeName =
        '\\\\.\\pipe\\wasapi_${pid}_${DateTime.now().millisecondsSinceEpoch}';

    _captureProcess = await Process.start(
      _wasapiCapturePath,
      ['-o', pipeName],
      runInShell: false,
    );

    // Drain stdout (pipe mode writes nothing there).
    _captureProcess!.stdout.drain<List<int>>();

    // wasapi_capture writes "WASAPI_RATE:<hz>" to stderr once the named pipe
    // is created and ready for FFmpeg to connect.
    final rateCompleter = Completer<int>();
    _captureProcess!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      logger.debug('[WasapiCapture] $line');
      if (!rateCompleter.isCompleted && line.startsWith('WASAPI_RATE:')) {
        final rate =
            int.tryParse(line.substring('WASAPI_RATE:'.length).trim()) ?? 48000;
        rateCompleter.complete(rate);
      }
    });

    final sampleRate = await rateCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        logger.warn('[WindowsRecorder] WASAPI_RATE timeout, using 48000');
        return 48000;
      },
    );

    logger.info(
      '[WindowsRecorder] wasapi_capture ready — rate=$sampleRate pipe=$pipeName',
    );

    // Single FFmpeg process: gdigrab (video) + named pipe (audio).
    // -shortest: finalizes the MP4 when the audio pipe closes (on stop).
    _ffmpegProcess = await Process.start(
      ffmpegPath,
      [
        '-f', 'gdigrab',
        '-framerate', '15',
        '-thread_queue_size', '4096',
        '-i', 'desktop',
        '-f', 's16le',
        '-ar', '$sampleRate',
        '-ac', '2',
        '-thread_queue_size', '4096',
        '-i', pipeName,
        '-vf', 'scale=1280:720',
        '-c:v', 'libx264',
        '-preset', 'ultrafast',
        '-pix_fmt', 'yuv420p',
        '-b:v', '5M',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
        '-shortest',
        '-y', filePath,
      ],
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );

    logger.info('[WindowsRecorder] FFmpeg started → $filePath');
    _ffmpegProcess!.stderr
        .transform(const SystemEncoding().decoder)
        .listen((line) => logger.debug('[FFmpeg] $line'));
  }

  @override
  Future<void> stop() async {
    // Closing wasapi_capture stdin triggers its exit, which closes the named
    // pipe. FFmpeg detects audio EOF and -shortest finalizes the MP4.
    if (_captureProcess != null) {
      try {
        await _captureProcess!.stdin.close().catchError((_) {});
        await _captureProcess!.exitCode.timeout(
          const Duration(seconds: 4),
          onTimeout: () {
            logger.warn('[WindowsRecorder] wasapi_capture timeout → killing');
            _captureProcess!.kill();
            return -1;
          },
        );
      } catch (e, st) {
        logger.error('[WindowsRecorder] wasapi_capture stop error', e, st);
      }
      _captureProcess = null;
    }

    if (_ffmpegProcess != null) {
      try {
        // FFmpeg finalizes after audio EOF; give it time to write the moov atom.
        await _ffmpegProcess!.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            logger.warn('[WindowsRecorder] FFmpeg timeout → killing');
            _ffmpegProcess!.kill();
            return -1;
          },
        );
      } catch (e, st) {
        logger.error('[WindowsRecorder] FFmpeg stop error', e, st);
      }
      _ffmpegProcess = null;
    }
  }
}
