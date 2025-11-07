abstract interface class Recorder {
  Future<void> start({required String recordingId});
  Future<void> stop();
  Future<void> upload();
  Future<void> cleanup();
}
