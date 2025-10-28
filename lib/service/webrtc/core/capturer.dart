import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/config/config.dart';
import 'package:webitel_agent_flutter/logger.dart';

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
      types: [SourceType.Screen, SourceType.Window],
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
