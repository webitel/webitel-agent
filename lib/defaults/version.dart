class AppVersions {
  static const String currentVersion = '1.0.0';
  static const int buildNumber = 1;

  static const List<String> versionHistory = [
    '1.0.0',
    '0.9.5',
    '0.9.0',
    '0.8.5',
  ];

  static String get fullVersion => '$currentVersion ($buildNumber)';
}
