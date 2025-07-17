import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';

final logger = LoggerService();

Future<MediaStream?> captureDesktopScreen() async {
  final int width = int.tryParse(dotenv.env['VIDEO_WIDTH'] ?? '') ?? 1920;
  final int height = int.tryParse(dotenv.env['VIDEO_HEIGHT'] ?? '') ?? 1080;
  final int frameRate = int.tryParse(dotenv.env['VIDEO_FRAMERATE'] ?? '') ?? 30;

  final Map<String, dynamic> constraints = {
    'video': {
      'displaySurface': 'monitor',
      'mandatory': {
        'maxWidth': width,
        'maxHeight': height,
        'maxFrameRate': frameRate,
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
