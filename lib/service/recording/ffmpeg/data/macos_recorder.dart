import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/ffmpeg_manager/ffmpeg_manager.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/domain/platform_recorder.dart';

class MacRecorder implements PlatformRecorder {
  Process? _process;

  /// FETCHES ACTIVE SCREEN INDICES USING THE FFMPEG BINARY
  Future<List<int>> _getMacScreenIndices(String ffmpegPath) async {
    // LIST DEVICES COMMAND FOR MACOS AVFOUNDATION
    final result = await Process.run(ffmpegPath, [
      '-f',
      'avfoundation',
      '-list_devices',
      'true',
      '-i',
      '0',
    ]);

    // FFMPEG OUTPUTS DEVICE LIST TO STDERR
    final logText = result.stderr.toString();
    final screenIndices = <int>[];
    final regex = RegExp(r'\[(\d+)\] Capture screen \d+');

    for (final match in regex.allMatches(logText)) {
      final index = int.tryParse(match.group(1) ?? '');
      if (index != null) screenIndices.add(index);
    }

    return screenIndices;
  }

  @override
  Future<void> start(String filePath) async {
    // GET THE EXECUTABLE PATH FROM FFMPEG MANAGER
    final ffmpegPath = await FFmpegManager.instance.path;
    final screenIndices = await _getMacScreenIndices(ffmpegPath);

    if (screenIndices.isEmpty) {
      throw Exception('ERROR: NO MACOS SCREENS DETECTED');
    }

    logger.info('STARTING MACOS RECORDING FOR SCREENS: $screenIndices');

    final List<String> args = [];

    // DEFINE INPUTS FOR EACH DETECTED SCREEN
    for (var index in screenIndices) {
      args.addAll([
        '-f', 'avfoundation',
        '-framerate', '15',
        '-pixel_format', 'nv12',
        '-i', '$index:none', // CAPTURE VIDEO ONLY, NO AUDIO
      ]);
    }

    // CONFIGURE VIDEO FILTERS AND ENCODING
    if (screenIndices.length == 1) {
      args.addAll(['-vf', 'scale=1280:720']);
    } else {
      // CONSTRUCT FILTER COMPLEX FOR MULTIPLE SCREENS (HSTACK)
      final stackChain = screenIndices
          .asMap()
          .entries
          .map((e) => '[${e.key}:v]scale=1280:720[v${e.key}]')
          .join(';');
      final inputChain =
          List.generate(screenIndices.length, (i) => '[v$i]').join();

      args.addAll([
        '-filter_complex',
        '$stackChain; $inputChain hstack=inputs=${screenIndices.length}',
      ]);
    }

    // OUTPUT SETTINGS USING APPLE HARDWARE ACCELERATION
    args.addAll([
      '-c:v', 'h264_videotoolbox', // USE VIDEOTOOLBOX FOR PERFORMANCE
      '-pix_fmt', 'yuv420p',
      '-b:v', '5M',
      '-movflags', '+faststart',
      '-y',
      filePath,
    ]);

    // START FFMPEG AS A SUBPROCESS
    _process = await Process.start(
      ffmpegPath,
      args,
      runInShell: false,
      workingDirectory: p.dirname(ffmpegPath),
    );

    // LISTEN TO STDERR FOR REAL-TIME FFMPEG STATUS OR ERRORS
    _process!.stderr.transform(utf8.decoder).listen((data) {
      if (data.contains('Error')) {
        logger.error('FFMPEG CORE ERROR: $data');
      }
    });

    logger.info('MACOS RECORDING INITIATED → $filePath');
  }

  @override
  Future<void> stop() async {
    if (_process == null) return;
    logger.info('STOPPING MACOS FFMPEG PROCESS');

    // SEND 'Q' TO STDIN TO STOP RECORDING GRACEFULLY
    _process!.stdin.writeln('q');
    await _process!.stdin.flush();

    // WAIT FOR PROCESS TO EXIT OR FORCE KILL AFTER TIMEOUT
    final exitCode = await _process!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        logger.warn('FFMPEG STOP TIMEOUT → KILLING PROCESS');
        _process!.kill();
        return -1;
      },
    );

    logger.info('FFMPEG EXITED WITH CODE: $exitCode');
    _process = null;
  }
}
