import 'dart:io';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/data/macos_recorder.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/data/video_storage.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/data/video_upload.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/data/windows_recorder.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/domain/platform_recorder.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/models/exception.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/models/state.dart';
import 'package:webitel_desk_track/service/recording/recorder.dart';
import 'package:webitel_desk_track/storage/storage.dart';

class LocalVideoRecorder implements Recorder {
  final String callId;
  final String agentToken;
  final String baseUrl;
  final String channel;

  late final PlatformRecorder _recorder;
  late final VideoUploadService _uploadService;
  late final FileStorageService _fileService;

  RecorderState _state = RecorderState.idle;
  String? _recordingFilePath;
  DateTime? _startTime;

  LocalVideoRecorder({
    required this.callId,
    required this.agentToken,
    required this.baseUrl,
    this.channel = 'screensharing',
  }) {
    _uploadService = VideoUploadService(
      baseUrl: baseUrl,
      agentToken: agentToken,
    );
    _fileService = FileStorageService();
    _recorder = Platform.isWindows ? WindowsRecorder() : MacRecorder();
  }

  bool get isRecording => _state == RecorderState.recording;

  @override
  Future<void> start({required String recordingId}) async {
    if (isRecording) return;
    if (!_fileService.isValidUuid(recordingId)) {
      throw RecordingException('Invalid recordingId');
    }

    final agentId =
        await SecureStorageService().readAgentId() ?? 'unknown_user';
    _recordingFilePath = await _fileService.buildRecordingFilePath(
      agentId as String,
    );

    _startTime = DateTime.now();

    await _recorder.start(_recordingFilePath!);
    _state = RecorderState.recording;
    logger.info('[LocalRecorder][$callId] Started → $_recordingFilePath');
  }

  @override
  Future<void> stop() async {
    if (!isRecording) return;
    await _recorder.stop();
    _state = RecorderState.idle;
    logger.info('[LocalRecorder][$callId] Stopped recording');
  }

  @override
  Future<void> upload() async {
    if (_recordingFilePath == null) {
      throw RecordingException('No file to upload');
    }

    _state = RecorderState.uploading;
    final success = await _uploadService.uploadWithRetry(
      filePath: _recordingFilePath!,
      callId: callId,
      channel: channel,
      startTime: _startTime,
    );

    _state = success ? RecorderState.completed : RecorderState.error;
  }

  @override
  Future<void> cleanup() async {
    await _fileService.cleanupOldVideos();
  }
}
