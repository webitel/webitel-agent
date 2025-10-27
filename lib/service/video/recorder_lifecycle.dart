import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/service/video/video_recorder.dart';

class RecorderLifecycleHandler with WidgetsBindingObserver {
  final LocalVideoRecorder? Function() getRecorder;
  bool _isCleaningUp = false;

  RecorderLifecycleHandler({required this.getRecorder});

  void init() {
    WidgetsBinding.instance.addObserver(this);

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      ProcessSignal.sigterm.watch().listen((_) => _onTerminate());
      ProcessSignal.sigint.watch().listen((_) => _onTerminate());
    }

    logger.info('RecorderLifecycleHandler initialized');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _onTerminate();
    }
  }

  Future<void> _onTerminate() async {
    if (_isCleaningUp) return;
    _isCleaningUp = true;

    final recorder = getRecorder();
    if (recorder == null) {
      logger.info('No active recorder on shutdown.');
      return;
    }

    try {
      logger.warn('App is terminating — stopping recording...');
      await recorder.stopRecording();

      logger.warn('Uploading last video before shutdown...');
      final uploaded = await recorder.uploadVideoWithRetry();

      if (uploaded) {
        logger.info('Upload completed successfully before shutdown.');
      } else {
        logger.error('Upload failed before shutdown.');
      }
    } catch (e, st) {
      logger.error('Error during graceful shutdown: $e', st);
    } finally {
      _isCleaningUp = false;
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
