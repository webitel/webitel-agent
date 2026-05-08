abstract interface class RecorderI {
  /// Starts the recording process.
  Future<void> start({required String recordingId});

  /// Stops the recording and releases resources.
  Future<void> stop();

  /// Uploads the recorded file (if applicable).
  Future<void> upload();

  /// Cleans up temporary files or states.
  Future<void> cleanup();
}
