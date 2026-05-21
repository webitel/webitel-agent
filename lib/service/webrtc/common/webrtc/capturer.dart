import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg/manager/manager.dart';

// wasapi_capture.exe is installed next to the main app executable by CMake.
String get _wasapiCapturePath {
  final appDir = p.dirname(Platform.resolvedExecutable);
  return p.join(appDir, 'wasapi_capture.exe');
}

Future<List<MediaStream>> captureAllDesktopScreensWindows(
  FFmpegMode mode,
  RTCPeerConnection pc,
) async {
  final config = AppConfig.instance;
  final int width = config.videoWidth;
  final int height = config.videoHeight;

  final List<MediaStream> streams = [];

  try {
    if (!Platform.isWindows) {
      throw Exception('captureAllDesktopScreensWindows() is Windows only');
    }

    logger.info('[Capturer] Enumerating desktop sources...');
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );

    if (sources.isEmpty) return [];

    final dataChannel = await pc.createDataChannel(
      'audio/mp3',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 0,
    );

    dataChannel.onDataChannelState = (state) {
      logger.info('[Capturer] DataChannel state: $state');
    };

    await startAudioCapture(dataChannel, mode);

    for (final source in sources) {
      final screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'mandatory': {'maxWidth': width, 'maxHeight': height},
          'optional': [
            {'scaleResolutionDownBy': 1.0},
          ],
        },
        'audio': false,
      });

      streams.add(screenStream);
      logger.info('[Capturer] Capture started for monitor ${source.name}');
    }

    return streams;
  } catch (e, st) {
    logger.error('[Capturer] Global capture error', e, st);
    return [];
  }
}

enum FFmpegMode { streaming, recording }

// Each mode stores a pair: (wasapi_capture process, ffmpeg process).
Process? _streamingCaptureProcess;
Process? _streamingFfmpegProcess;
Process? _recordingCaptureProcess;
Process? _recordingFfmpegProcess;

Future<void> startAudioCapture(
  RTCDataChannel audioChannel,
  FFmpegMode mode,
) async {
  final ffmpegPath = await FFmpegManager.instance.path;
  final capturePath = _wasapiCapturePath;

  logger.info('[Capturer] Starting wasapi_capture ($mode): $capturePath');

  final captureProcess = await Process.start(
    capturePath,
    [],
    runInShell: false,
  );

  // wasapi_capture outputs s16le 48000Hz stereo PCM on stdout.
  // FFmpeg reads it from pipe:0 and encodes to MP3.
  final ffmpegArgs = [
    '-f', 's16le',
    '-ar', '48000',
    '-ac', '2',
    '-i', 'pipe:0',
    '-c:a', 'libmp3lame',
    '-b:a', '128k',
    '-fflags', '+nobuffer',
    '-flush_packets', '1',
    '-f', 'mp3',
    'pipe:1',
  ];

  logger.info('[Capturer] Starting FFmpeg ($mode): ffmpeg ${ffmpegArgs.join(' ')}');

  final ffmpegProcess = await Process.start(
    ffmpegPath,
    ffmpegArgs,
    runInShell: false,
    workingDirectory: p.dirname(ffmpegPath),
  );

  if (mode == FFmpegMode.streaming) {
    _streamingCaptureProcess = captureProcess;
    _streamingFfmpegProcess  = ffmpegProcess;
  } else {
    _recordingCaptureProcess = captureProcess;
    _recordingFfmpegProcess  = ffmpegProcess;
  }

  // Pipe PCM from wasapi_capture stdout → FFmpeg stdin.
  captureProcess.stdout.pipe(ffmpegProcess.stdin).catchError((e) {
    logger.error('[Capturer] PCM pipe error', e);
  });

  captureProcess.stderr
      .transform(const SystemEncoding().decoder)
      .listen((line) => logger.debug('[WasapiCapture] $line'));

  ffmpegProcess.stderr
      .transform(const SystemEncoding().decoder)
      .listen((line) => logger.debug('[FFmpeg STDERR] $line'));

  const chunkSize = 4096;
  ffmpegProcess.stdout.listen(
    (chunk) {
      int offset = 0;
      while (offset < chunk.length) {
        final end = (offset + chunkSize < chunk.length)
            ? offset + chunkSize
            : chunk.length;
        final subchunk = Uint8List.fromList(chunk.sublist(offset, end));

        if (audioChannel.state == RTCDataChannelState.RTCDataChannelOpen) {
          audioChannel.send(RTCDataChannelMessage.fromBinary(subchunk));
        }

        offset = end;
      }
    },
    onDone: () {
      logger.info('[Capturer] FFmpeg stdout done, closing DataChannel');
      audioChannel.close();
    },
    onError: (e) => logger.error('[Capturer] FFmpeg stdout error', e),
    cancelOnError: true,
  );
}

Future<void> stopStereoAudioFFmpeg(FFmpegMode mode) async {
  Process? captureProcess;
  Process? ffmpegProcess;

  if (mode == FFmpegMode.streaming) {
    captureProcess = _streamingCaptureProcess;
    ffmpegProcess  = _streamingFfmpegProcess;
  } else {
    captureProcess = _recordingCaptureProcess;
    ffmpegProcess  = _recordingFfmpegProcess;
  }

  // Stop wasapi_capture first — closing its stdout will close FFmpeg's stdin,
  // which lets FFmpeg finish muxing and exit naturally.
  if (captureProcess != null) {
    try {
      captureProcess.kill(ProcessSignal.sigterm);
      await captureProcess.exitCode
          .timeout(const Duration(seconds: 2), onTimeout: () {
        captureProcess?.kill(ProcessSignal.sigkill);
        return -1;
      });
    } catch (e, st) {
      logger.error('[Capturer] wasapi_capture shutdown error', e, st);
    }
  }

  if (ffmpegProcess != null) {
    try {
      // Give FFmpeg a moment to flush after stdin closes.
      await ffmpegProcess.exitCode
          .timeout(const Duration(seconds: 3), onTimeout: () {
        ffmpegProcess?.kill(ProcessSignal.sigkill);
        return -1;
      });
      await ffmpegProcess.stdin.close();
    } catch (e, st) {
      logger.error('[Capturer] FFmpeg shutdown error', e, st);
    }
  }

  if (mode == FFmpegMode.streaming) {
    _streamingCaptureProcess = null;
    _streamingFfmpegProcess  = null;
  } else {
    _recordingCaptureProcess = null;
    _recordingFfmpegProcess  = null;
  }

  logger.info('[Capturer] Audio processes stopped ($mode).');
}

Future<MediaStream?> captureDesktopScreen() async {
  final config = AppConfig.instance;
  final int width = config.videoWidth;
  final int height = config.videoHeight;

  try {
    logger.info('[Capturer] Starting screen capture');

    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );
    final source = sources.first;

    final screenStream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': source.id,
        'mandatory': {'maxWidth': width, 'maxHeight': height},
      },
      'audio': true,
    });

    final systemAudioTracks = screenStream.getAudioTracks();
    logger.info(
      '[Capturer] System audio tracks captured: ${systemAudioTracks.length}',
    );

    logger.info('[Capturer] Screen + mic capture started successfully');
    return screenStream;
  } catch (e, st) {
    logger.error('[Capturer] Error capturing screen', e, st);
    return null;
  }
}
