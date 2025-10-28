import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

import '../../logger.dart' show logger;

class LocalVideoRecorder {
  final String callId;
  final String agentToken;
  final String baseUrl;
  final String channel;

  File? _videoFile;
  IOSink? _fileSink;
  bool _isRecording = false;
  final _logger = logger;
  FFmpegSession? _currentSession;

  static const int maxRetries = 3;
  static const Duration retryDelay = Duration(seconds: 2);

  Process? _windowsProcess;

  String? _recordingFilePath;

  LocalVideoRecorder({
    required this.callId,
    required this.agentToken,
    required this.baseUrl,
    this.channel = 'screensharing',
  });

  Future<Directory> _getVideoDirectory() async {
    final dir = await getTemporaryDirectory();
    final recordingsDir = Directory('${dir.path}/recordings');
    if (!await recordingsDir.exists()) {
      await recordingsDir.create(recursive: true);
    }
    return recordingsDir;
  }

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

    debugPrint('Detected screens: $screenIndices');

    return screenIndices;
  }

  int getWindowsMonitorCount() {
    return GetSystemMetrics(SM_CMONITORS);
  }

  // RFC4122 UUID v1-v5 pattern
  static final RegExp _uuidRegExp = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  bool _isValidUuid(String id) => _uuidRegExp.hasMatch(id);

  Future<void> startRecording({required String recordingId}) async {
    if (_isRecording) return;

    // Validate recordingId as UUID — reject if invalid
    if (!_isValidUuid(recordingId)) {
      _logger.error('Invalid recordingId provided: $recordingId');
      throw ArgumentError('Invalid recordingId');
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    String? ffmpegCommand;

    final directory = await _getVideoDirectory();
    final filePath = '${directory.path}/${recordingId}_$timestamp.mp4';
    _recordingFilePath = filePath;
    _videoFile = File(filePath);

    // macOS screen recording logic using FFmpeg with hardware acceleration
    //
    // This block is only executed on macOS platforms because it relies on
    // the `avfoundation` input device, which is specific to macOS.
    //
    // 1. Retrieve available screen indices on the Mac using `getMacScreenIndices()`.
    //    This returns a list of integers representing each connected display.
    //    Logging is used to verify which screens are detected.
    //
    // 2. If no screens are detected, throw an exception immediately.
    //    This prevents attempting an FFmpeg command with invalid inputs.
    //
    // 3. Construct FFmpeg input arguments for each screen:
    //    - `-f avfoundation` specifies the input device format (macOS screen capture).
    //    - `-framerate 15` lowers the frame rate to reduce CPU load while recording.
    //      (Higher FPS increases CPU usage.)
    //    - `-pixel_format nv12` selects a format optimized for hardware encoding on Mac.
    //    - `"$i:none"` captures only video for the given screen index; audio is disabled.
    //
    // 4. Single screen case:
    //    - If only one screen is detected, simply scale the video to 1280x720
    //      to reduce resolution and CPU load while maintaining reasonable quality.
    //    - Use `h264_videotoolbox` for hardware-accelerated H.264 encoding,
    //      which offloads encoding from the CPU to the GPU/Video Toolbox.
    //    - `-pix_fmt yuv420p` ensures compatibility with most players.
    //    - `-b:v 5M` sets a reasonable bitrate for 720p, balancing quality and file size.
    //    - `-y` overwrites the output file if it exists.
    //
    // 5. Multiple screens case:
    //    - Each screen stream is scaled individually to 1280x720 to normalize resolution.
    //    - Each scaled stream is labeled as `[v0]`, `[v1]`, etc., for filter chaining.
    //    - All labeled streams are horizontally stacked using `hstack=inputs=N`.
    //      This creates a single combined video showing all screens side by side.
    //    - Use the same hardware-accelerated H.264 encoding and pixel format as above.
    //    - The final command produces a single MP4 file containing all screen captures.
    //
    // Overall, this setup prioritizes:
    //    - CPU efficiency by using hardware encoding and lower frame rates.
    //    - Compatibility by using H.264 with `yuv420p` pixel format.
    //    - Multi-screen support by dynamically building filter chains.

    if (Platform.isMacOS) {
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

      if (screenIndices.length == 1) {
        ffmpegCommand =
            '$inputArgs -vf "scale=1280:720" -c:v h264_videotoolbox -pix_fmt yuv420p -b:v 5M -movflags +faststart -y $filePath';
      } else {
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
            '-c:v h264_videotoolbox -pix_fmt yuv420p -b:v 5M -movflags +faststart -y $filePath';
      }
    } else if (Platform.isWindows) {
      _startRecordingWindows(filePath);
      return;
    } else {
      throw UnsupportedError('Recording not supported on this platform');
    }

    _isRecording = true;

    logger.info('Executing FFmpeg command:\n$ffmpegCommand');

    _currentSession = await FFmpegKit.executeAsync(ffmpegCommand ?? '', (
      session,
    ) async {
      final returnCode = await session.getReturnCode();
      final logs = await session.getAllLogsAsString();

      if (ReturnCode.isSuccess(returnCode)) {
        if (_recordingFilePath != null &&
            File(_recordingFilePath!).existsSync()) {
          final fileSize = await File(_recordingFilePath!).length();
          logger.info(
            'Recording saved: $_recordingFilePath (${fileSize ~/ 1024} KB)',
          );
        } else {
          logger.error('File not created: $_recordingFilePath');
        }
      } else {
        logger.error('Recording failed with return code $returnCode');
        logger.warn('FFmpeg logs:\n$logs');
      }

      _isRecording = false;
    });

    logger.info('Started screen recording to $_recordingFilePath');
  }

  Future<void> _startRecordingWindows(String filePath) async {
    _windowsProcess = await Process.start('ffmpeg', [
      '-f', 'gdigrab', // Windows screen grabber
      '-framerate', '15',
      '-i', 'desktop',
      '-vf', 'scale=1280:720',
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-pix_fmt', 'yuv420p',
      '-b:v', '5M',
      '-movflags', '+faststart',
      '-y', filePath,
    ], runInShell: true);

    _isRecording = true;
    logger.info('🎥 FFmpeg recording started (Windows): $filePath');

    _windowsProcess!.stderr
        .transform(SystemEncoding().decoder)
        .listen((data) => logger.info('FFmpeg: $data'));
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    //FIXME removed as Windows use Process, not FFmpegSession
    // MacOS can still use FFmpegSession
    // || _currentSession == null

    debugPrint('Stopping recording gracefully...');

    try {
      if (Platform.isWindows) {
        await _stopRecordingWindows();
        return;
      }

      await _currentSession?.cancel();
      _currentSession = null;

      await Future.delayed(const Duration(seconds: 1));

      if (_recordingFilePath != null &&
          File(_recordingFilePath!).existsSync()) {
        final fileSize = await File(_recordingFilePath!).length();
        debugPrint('Recording stopped, file size: ${fileSize ~/ 1024} KB');
      } else {
        debugPrint('File not found after stop');
      }
    } catch (e) {
      debugPrint('Error stopping recording: $e');
    }

    _isRecording = false;
  }

  Future<void> _stopRecordingWindows() async {
    if (_windowsProcess == null) {
      logger.warn('No FFmpeg process to stop');
      return;
    }

    logger.info('Stopping FFmpeg recording...');

    try {
      // On Windows, FFmpeg expects 'q' via stdin to stop recording gracefully
      _windowsProcess!.stdin.writeln('q');
      await _windowsProcess!.stdin.flush();
      await _windowsProcess!.stdin.close();

      // Wait for the process to exit with a timeout
      final exitCode = await _windowsProcess!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          logger.warn('FFmpeg did not exit in time, killing process...');
          _windowsProcess!.kill(); // Force kill
          return -1;
        },
      );

      logger.info(
        exitCode != -1
            ? 'FFmpeg recording stopped with exit code $exitCode'
            : 'FFmpeg was force killed',
      );
    } catch (e) {
      logger.error('Error stopping FFmpeg: $e');
    } finally {
      _windowsProcess = null;
      _isRecording = false;
    }
  }

  Future<bool> uploadVideoWithRetry() async {
    if (_videoFile == null) {
      _logger.warn('No video file to upload, skipping retries');
      return false;
    }

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      _logger.info('Upload attempt $attempt of $maxRetries');
      final success = await uploadVideo();
      if (success) return true;

      if (attempt < maxRetries) {
        _logger.warn(
          'Upload failed, retrying in ${retryDelay.inSeconds} seconds...',
        );
        await Future.delayed(retryDelay);
      }
    }

    _logger.error('Failed to upload video after $maxRetries attempts');
    return false;
  }

  Future<bool> uploadVideo() async {
    if (_videoFile == null || !await _videoFile!.exists()) {
      _logger.error('No video file to upload');
      return false;
    }

    try {
      final uri = Uri.parse('$baseUrl/api/storage/file/$callId/upload').replace(
        queryParameters: {
          'channel': channel,
          'access_token': agentToken,
          'thumbnail': 'true',
        },
      );

      _logger.info('Uploading video to: $uri');

      final request = http.MultipartRequest('POST', uri);
      final mimeType = lookupMimeType(_videoFile!.path) ?? 'video/mp4';
      final mimeParts = mimeType.split('/');
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          _videoFile!.path,
          contentType: MediaType(mimeParts[0], mimeParts[1]),
          filename: _videoFile!.path.split('/').last,
        ),
      );

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        _logger.info('Video uploaded successfully');
        // await _deleteLocalFile();
        return true;
      } else {
        _logger.error(
          '❌ Upload failed: ${response.statusCode} ${response.body}',
        );
        return false;
      }
    } catch (e) {
      _logger.error('Error uploading video: $e');
      return false;
    }
  }

  Future<double> getFileSizeMB() async {
    if (_videoFile == null || !await _videoFile!.exists()) return 0;
    final bytes = await _videoFile!.length();
    return bytes / (1024 * 1024);
  }

  Future<bool> isFileValid() async {
    if (_videoFile == null || !await _videoFile!.exists()) return false;
    try {
      final size = await _videoFile!.length();
      return size > 0;
    } catch (e) {
      _logger.error('Error checking file validity: $e');
      return false;
    }
  }

  static Future<void> cleanupOldVideos() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final videoDir = Directory('${appDir.path}/recordings');
      if (!await videoDir.exists()) return;

      await for (final entity in videoDir.list()) {
        if (entity is File) {
          await entity.delete();
          logger.info('Deleted video: ${entity.path}');
        }
      }

      logger.info('Cleanup complete');
    } catch (e) {
      logger.error('Failed to cleanup videos: $e');
    }
  }

  void dispose() {
    _fileSink?.close();
  }
}
