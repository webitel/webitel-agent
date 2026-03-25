abstract interface class PlatformRecorder {
  Future<void> start(String filePath);
  Future<void> stop();
}
