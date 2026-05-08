import 'dart:io';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/data/macos_recorder.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/data/video_storage.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/data/video_upload.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/data/windows_recorder.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/domain/platform_recorder.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/models/exception.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/models/state.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';

class LocalVideoRecorder implements RecorderI {
  final String callId;
  final String agentToken;
  final String baseUrl;
  final String channel;
  final IStorageService _storage; // Injected interface

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
    required IStorageService storage, // Added to constructor
    this.channel = 'screenrecording',
  }) : _storage = storage {
    _uploadService = VideoUploadService(
      baseUrl: baseUrl,
      agentToken: agentToken,
    );
    _fileService = FileStorageService();

    // Choose platform implementation
    _recorder = Platform.isWindows ? WindowsRecorder() : MacRecorder();
  }

  bool get isRecording => _state == RecorderState.recording;

  @override
  Future<void> start({required String recordingId}) async {
    if (isRecording) return;

    if (!_fileService.isValidUuid(recordingId)) {
      throw RecordingException('Invalid recordingId: $recordingId');
    }

    try {
      // Use the injected storage instead of creating a new instance
      final agentId =
          (await _storage.readAgentId())?.toString() ?? 'unknown_user';

      _recordingFilePath = await _fileService.buildRecordingFilePath(agentId);
      _startTime = DateTime.now();

      logger.info('[LocalRecorder][$callId] Initializing FFmpeg process...');
      await _recorder.start(_recordingFilePath!);

      _state = RecorderState.recording;
      logger.info('[LocalRecorder][$callId] Started → $_recordingFilePath');
    } catch (e, st) {
      _state = RecorderState.error;
      logger.error(
        '[LocalRecorder][$callId] Failed to start local recording',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!isRecording) {
      logger.warn(
        '[LocalRecorder][$callId] Stop requested but recorder is not active.',
      );
      return;
    }

    try {
      await _recorder.stop();
      _state = RecorderState.idle;
      logger.info('[LocalRecorder][$callId] Stopped recording session.');
    } catch (e, st) {
      logger.error('[LocalRecorder][$callId] Error during FFmpeg stop', e, st);
      _state = RecorderState.error;
    }
  }

  @override
  Future<void> upload() async {
    if (_recordingFilePath == null) {
      throw RecordingException('No recording file path available for upload.');
    }

    final file = File(_recordingFilePath!);
    if (!await file.exists()) {
      logger.error(
        '[LocalRecorder][$callId] Upload failed: File does not exist at $_recordingFilePath',
      );
      return;
    }

    _state = RecorderState.uploading;
    logger.info('[LocalRecorder][$callId] Starting file upload to server...');

    final success = await _uploadService.uploadWithRetry(
      filePath: _recordingFilePath!,
      callId: callId,
      channel: channel,
      startTime: _startTime,
    );

    if (success) {
      _state = RecorderState.completed;
      logger.info('[LocalRecorder][$callId] Upload finished successfully.');
    } else {
      _state = RecorderState.error;
      logger.warn('[LocalRecorder][$callId] Upload failed after retries.');
    }
  }

  @override
  Future<void> cleanup() async {
    logger.info('[LocalRecorder] Running storage cleanup...');
    await _fileService.cleanupOldVideos();
  }
}
