import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/config/config.dart';
import 'package:webitel_agent_flutter/core/logger.dart';

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
        'audio': false,
      };

      try {
        final stream = await navigator.mediaDevices.getDisplayMedia(
          constraints,
        );
        streams.add(stream);

        logger.info('[Capturer] ✅ Capture started for ${source.name}');
      } catch (e, st) {
        logger.error('[Capturer] ❌ Error capturing ${source.name}', e, st);
      }
    }

    logger.info(
      '[Capturer] All monitors captured: ${streams.length} streams total',
    );

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
    logger.info(
      '[Capturer] Starting screen capture: width=$width, height=$height, frameRate=$frameRate',
    );

    List<DesktopCapturerSource> sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
    );

    final Map<String, dynamic> constraints = {
      'video': {
        !Platform.isWindows ? 'displaySurface' : 'monitor': '',
        Platform.isWindows ? 'deviceId' : sources.first.id: '',
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
    };

    final stream = await mediaDevices.getDisplayMedia(constraints);

    logger.info('[Capturer] Screen capture started successfully');

    return stream;
  } catch (e, st) {
    logger.error('[Capturer] Error capturing screen', e, st);
    return null;
  }
}
