import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/config/config.dart';
import 'package:webitel_agent_flutter/logger.dart';

Future<MediaStream?> captureDesktopScreen() async {
  final config = AppConfig.instance;

  final int width = config?.videoWidth ?? 1920;
  final int height = config?.videoHeight ?? 1080;
  final int frameRate = config?.videoFramerate ?? 30;

  final Map<String, dynamic> constraints = {
    'video': {
      'displaySurface': 'monitor',
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
    logger.info(
      '[Capturer] Starting screen capture: width=$width, height=$height, frameRate=$frameRate',
    );

    final stream = await mediaDevices.getDisplayMedia(constraints);

    logger.info('[Capturer] Screen capture started successfully');

    return stream;
  } catch (e, st) {
    logger.error('[Capturer] Error capturing screen', e, st);
    return null;
  }
}
