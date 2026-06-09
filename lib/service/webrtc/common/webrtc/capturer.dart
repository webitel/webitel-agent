import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';

Future<List<MediaStream>> captureAllDesktopScreensWindows(
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

    for (final source in sources) {
      final screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'mandatory': {'maxWidth': width, 'maxHeight': height},
          'optional': [
            {'scaleResolutionDownBy': 1.0},
          ],
        },
        'audio': true,
      });

      streams.add(screenStream);
      logger.info('[Capturer] Capture started for monitor ${source.name}');
      for (final t in screenStream.getAudioTracks()) {
        final settings = t.getSettings();
        logger.info('[Capturer] Loopback track: id=${t.id} sampleRate=${settings['sampleRate']} channels=${settings['channelCount']}');
      }
    }

    // Microphone as a separate WebRTC audio track.
    try {
      final micStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      streams.add(micStream);
      for (final t in micStream.getAudioTracks()) {
        final settings = t.getSettings();
        logger.info('[Capturer] Mic track: id=${t.id} sampleRate=${settings['sampleRate']} channels=${settings['channelCount']}');
      }
    } catch (e) {
      logger.warn('[Capturer] Mic capture failed (no mic?): $e');
    }

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

    final audioTracks = screenStream.getAudioTracks();
    logger.info('[Capturer] Audio tracks captured: ${audioTracks.length}');

    return screenStream;
  } catch (e, st) {
    logger.error('[Capturer] Error capturing screen', e, st);
    return null;
  }
}
