import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg_manager/ffmpeg_manager.dart';

Future<String?> getStereoMixDeviceId() async {
  final ffmpegPath = await FFmpegManager.instance.path;
  final ffmpegProcess = await Process.start(ffmpegPath, [
    '-list_devices',
    'true',
    '-f',
    'dshow',
    '-i',
    'dummy',
  ], runInShell: true);

  await for (var line in ffmpegProcess.stderr
      .transform(utf8.decoder)
      .transform(LineSplitter())) {
    if (line.contains('Stereo') && line.contains('"')) {
      final match = RegExp(r'"(.*)"').firstMatch(line);
      if (match != null) return match.group(1);
    }
  }

  await ffmpegProcess.exitCode;
  return null;
}

Future<List<MediaStream>> captureAllDesktopScreensWindows(
  FFmpegMode mode,
  RTCPeerConnection pc,
) async {
  final config = AppConfig.instance;
  final int width = config.videoWidth;
  final int height = config.videoHeight;
  final int frameRate = config.videoFramerate;

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
      'audio/opus',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 0,
    );

    dataChannel.onDataChannelState = (state) {
      logger.info('[Capturer] DataChannel state: $state');
    };

    final deviceId = await getStereoMixDeviceId();
    if (deviceId == null) {
      logger.error('[Capturer] Stereo Mix device not found!');
      return [];
    }
    logger.info('[Capturer] Using Stereo Mix device: $deviceId');

    for (final source in sources) {
      final screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': source.id,
          'mandatory': {
            'maxWidth': width + 10,
            'minWidth': width - 10,
            'maxHeight': height + 10,
            'minHeight': height - 10,
            'maxFramerate': frameRate,
            'frameRate': frameRate.toDouble(),
          },
        },
        'audio': false,
      });

      final micStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
      });
      for (final track in micStream.getAudioTracks()) {
        screenStream.addTrack(track);
      }

      await startStreamingFFmpeg(deviceId, dataChannel, 48 * 1000, mode);

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
  String deviceId,
  RTCDataChannel audioChannel,
  int bitrate,
  FFmpegMode mode,
) async {
  final ffmpegArgs = [
    '-f', 'dshow',
    '-i', 'audio=$deviceId', // input with Stereo Mix
    '-c:a', 'libmp3lame', // codec MP3
    '-b:a', '${bitrate}k', // bitrate
    '-ar', '44100', // frequency
    '-ac', '2', // stereo
    '-fflags', '+nobuffer', // turn off buffering
    '-flush_packets', '1', // flush packets immediately
    '-f', 'mp3', // MP3 container
    'pipe:1', // output в stdout
  ];

  logger.info(
    '[Capturer] Starting FFmpeg ($mode): ffmpeg ${ffmpegArgs.join(' ')}',
  );
  final ffmpegPath = await FFmpegManager.instance.path;
  final process = await Process.start(ffmpegPath, ffmpegArgs, runInShell: true);

  if (mode == FFmpegMode.streaming) {
    _streamingProcess = process;
  } else {
    _recordingProcess = process;
  }

  process.stderr
      .transform(utf8.decoder)
      .transform(LineSplitter())
      .listen((line) => logger.debug('[FFmpeg STDERR] $line'));

  // stdout → DataChannel
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
  final int frameRate = config.videoFramerate;

  try {
    logger.info('[Capturer] Starting screen capture');

    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );
    final source = sources.first;

    final screenStream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': source.id,
        'mandatory': {
          'maxWidth': width,
          'maxHeight': height,
          'maxFramerate': frameRate,
        },
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
