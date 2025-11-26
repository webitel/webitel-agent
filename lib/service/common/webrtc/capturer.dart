import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:path/path.dart' as p;
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg_manager/ffmpeg_manager.dart';

Future<String?> getStereoMixDeviceId() async {
  final ffmpegPath = await FFmpegManager.instance.path;
  logger.info('[StereoMix] Using FFmpeg at: $ffmpegPath');

  final ffmpegProcess = await Process.start(
    ffmpegPath,
    ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
    runInShell: false,
    workingDirectory: p.dirname(ffmpegPath),
  );

  await for (var line in ffmpegProcess.stderr
      .transform(utf8.decoder)
      .transform(LineSplitter())) {
    logger.info('[FFMPEG STDERR] $line');

    if (line.contains('Stereo') && line.contains('"')) {
      final match = RegExp(r'"(.*)"').firstMatch(line);
      if (match != null) {
        final device = match.group(1);
        logger.info('[StereoMix] Found device: $device');
        return device;
      }
    }
  }

  final exitCode = await ffmpegProcess.exitCode;
  logger.info('[FFMPEG] Process exited with code: $exitCode');

  return null;
}

Future<String?> getMicrophoneDeviceId() async {
  final ffmpegPath = await FFmpegManager.instance.path;
  final ffmpegProcess = await Process.start(
    ffmpegPath,
    ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
    runInShell: false,
    workingDirectory: p.dirname(ffmpegPath),
  );

  String? micId;
  await for (var line in ffmpegProcess.stderr
      .transform(utf8.decoder)
      .transform(LineSplitter())) {
    if (line.contains('Microphone') && line.contains('"')) {
      final match = RegExp(r'"(.*)"').firstMatch(line);
      if (match != null) micId = match.group(1);
    }
  }

  await ffmpegProcess.exitCode;
  return micId;
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

    final stereoMixId = await getStereoMixDeviceId();
    final micId = await getMicrophoneDeviceId();

    if (stereoMixId == null || micId == null) {
      logger.error('[Capturer] Stereo Mix or Microphone not found!');
      return [];
    }
    logger.info(
      '[Capturer] Using Stereo Mix: $stereoMixId, Microphone: $micId',
    );

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

      // FIXME
      // final micStream = await navigator.mediaDevices.getUserMedia({
      //   'audio': true,
      // });
      // for (final track in micStream.getAudioTracks()) {
      //   screenStream.addTrack(track);
      // }

      await startStreamingFFmpeg(
        stereoMixId,
        micId,
        dataChannel,
        48 * 1000,
        mode,
      );

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

Process? _streamingProcess;
Process? _recordingProcess;

Future<Process?> startStreamingFFmpeg(
  String stereoMixId,
  String micId,
  RTCDataChannel audioChannel,
  int bitrate,
  FFmpegMode mode,
) async {
  final ffmpegArgs = [
    '-f', 'dshow', // DirectShow input
    '-i', 'audio=$stereoMixId', // Stereo Mix input
    '-f', 'dshow',
    '-i', 'audio=$micId', // Microphone input
    '-filter_complex',
    '[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0', // Mix audio
    '-c:a', 'libmp3lame', // MP3 encoder
    '-b:a', '${bitrate}k', // Bitrate
    '-ar', '44100', // Sample rate
    '-ac', '2', // Stereo
    '-fflags', '+nobuffer', // Low latency
    '-flush_packets', '1', // Flush packets immediately
    '-f', 'mp3', // Output format
    'pipe:1', // Output to stdout
  ];

  logger.info(
    '[Capturer] Starting FFmpeg ($mode): ffmpeg ${ffmpegArgs.join(' ')}',
  );

  final ffmpegPath = await FFmpegManager.instance.path;
  final process = await Process.start(
    ffmpegPath,
    ffmpegArgs,
    runInShell: false,
    workingDirectory: p.dirname(ffmpegPath),
  );

  if (mode == FFmpegMode.streaming) {
    _streamingProcess = process;
  } else {
    _recordingProcess = process;
  }

  process.stderr
      .transform(utf8.decoder)
      .transform(LineSplitter())
      .listen((line) => logger.debug('[FFmpeg STDERR] $line'));

  const chunkSize = 4096;
  process.stdout.listen(
    (chunk) {
      int offset = 0;
      while (offset < chunk.length) {
        final end =
            (offset + chunkSize < chunk.length)
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

  return process;
}

Future<void> stopStereoAudioFFmpeg(FFmpegMode mode) async {
  Process? process;
  if (mode == FFmpegMode.streaming) process = _streamingProcess;
  if (mode == FFmpegMode.recording) process = _recordingProcess;

  if (process == null) return;

  try {
    process.stdin.writeln('q');
    await process.stdin.flush();
    await process.stdin.close();

    await process.stdout.drain();
    await process.stderr.drain();

    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        logger.warn('[Capturer] FFmpeg did not exit, killing process');
        process?.kill();
        return -1;
      },
    );
  } catch (e, st) {
    logger.error('[Capturer] Error stopping FFmpeg', e, st);
  } finally {
    if (mode == FFmpegMode.streaming) _streamingProcess = null;
    if (mode == FFmpegMode.recording) _recordingProcess = null;
  }
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

    final mediaDevices = navigator.mediaDevices;
    var devices = await mediaDevices.enumerateDevices();
    logger.info(
      '[Capturer] Enumerated media devices for mic: ${devices.length}',
    );

    final micStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
    });

    for (final track in micStream.getAudioTracks()) {
      screenStream.addTrack(track);
    }

    logger.info('[Capturer] Screen + mic capture started successfully');
    return screenStream;
  } catch (e, st) {
    logger.error('[Capturer] Error capturing screen', e, st);
    return null;
  }
}
