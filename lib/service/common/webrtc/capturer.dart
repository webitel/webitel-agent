import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';

Future<List<MediaStream>> captureAllDesktopScreensWindows() async {
  final config = AppConfig.instance;
  final int width = config.videoWidth;
  final int height = config.videoHeight;
  final int frameRate = config.videoFramerate;

  final List<MediaStream> streams = [];

  try {
    if (!Platform.isWindows) {
      throw Exception(
        'captureAllDesktopScreensWindows() available only on Windows',
      );
    }

    logger.info('[Capturer] Enumerating all desktop sources...');
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );

    if (sources.isEmpty) {
      logger.error('[Capturer] No desktop sources found');
      return [];
    }

    for (final source in sources) {
      logger.info(
        '[Capturer] Starting capture for monitor: ${source.name} (${source.id})',
      );

      final constraints = {
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
        // getDisplayMedia(audio: true) → NOT reliable for system audio,
        // so we’ll handle mic audio separately below.
        'audio': false,
      };

      try {
        // 🖥️ Start screen capture
        final screenStream = await navigator.mediaDevices.getDisplayMedia(
          constraints,
        );

        // 🎤 Add microphone audio
        final micStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
        });

        // Add mic track(s) to the screen stream
        for (final track in micStream.getAudioTracks()) {
          screenStream.addTrack(track);
        }

        streams.add(screenStream);

        logger.info(
          '[Capturer] Capture (screen + mic) started for ${source.name}',
        );
      } catch (e, st) {
        logger.error('[Capturer] Error capturing ${source.name}', e, st);
      }
    }

    logger.info('[Capturer] All monitors captured: ${streams.length} total');

    return streams;
  } catch (e, st) {
    logger.error('[Capturer] Global capture error', e, st);
    return [];
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
