import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/domain/platform_recorder.dart';

class MacRecorder implements PlatformRecorder {
  FFmpegSession? _session;
  bool _isRecording = false;

  Future<List<int>> getMacScreenIndices() async {
    const command = '-f avfoundation -list_devices true -i 0';

    final session = await FFmpegKit.execute(command);
    final logs = await session.getLogs();
    final logText = logs.map((log) => log.getMessage()).join('\n');

    final screenIndices = <int>[];
    final regex = RegExp(r'\[(\d+)\] Capture screen \d+');

    for (final match in regex.allMatches(logText)) {
      final index = int.tryParse(match.group(1) ?? '');
      if (index != null) screenIndices.add(index);
    }

    logger.debug('Detected screens: $screenIndices');

    return screenIndices;
  }

  @override
  Future<void> start(String filePath) async {
    final screenIndices = await getMacScreenIndices();
    logger.info('Found Mac screens: $screenIndices');

    if (screenIndices.isEmpty) {
      throw Exception('No screens detected for recording.');
    }

    final inputArgs = screenIndices
        .map(
          (i) =>
              '-f avfoundation -framerate 15 -pixel_format nv12 -i "$i:none"',
        )
        .join(' ');

    late final String ffmpegCommand;

    if (screenIndices.length == 1) {
      // one screen
      ffmpegCommand =
          '$inputArgs -vf "scale=1280:720" -c:v h264_videotoolbox '
          '-pix_fmt yuv420p -b:v 5M -movflags +faststart -y "$filePath"';
    } else {
      // multiple screens - stack horizontally
      final stackChain = screenIndices
          .asMap()
          .entries
          .map((entry) {
            final i = entry.key;
            return '[$i:v]scale=1280:720[v$i]';
          })
          .join(';');

      final inputChain =
          List.generate(screenIndices.length, (i) => '[v$i]').join();

      ffmpegCommand =
          '$inputArgs -filter_complex "$stackChain;$inputChain hstack=inputs=${screenIndices.length}" '
          '-c:v h264_videotoolbox -pix_fmt yuv420p -b:v 5M -movflags +faststart -y "$filePath"';
    }

    logger.info('Starting FFmpeg on macOS → $filePath');
    _isRecording = true;

    _session = await FFmpegKit.executeAsync(ffmpegCommand, (session) async {
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        logger.info('Recording saved → $filePath');
      } else {
        logger.error('Recording failed: $returnCode');
      }
      _isRecording = false;
    });
  }

  @override
  Future<void> stop() async {
    if (!_isRecording) return;
    logger.info('Stopping macOS recording');
    await _session?.cancel();
    _isRecording = false;
  }
}
