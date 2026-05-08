class RecordingException implements Exception {
  final String message;
  RecordingException(this.message);
  @override
  String toString() => 'RecordingException: $message';
}
