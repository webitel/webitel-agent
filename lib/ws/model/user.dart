class UserDeviceConfig {
  final String authorizationUser;
  final String displayName;
  final String extension;
  final String ha1;
  final String realm;
  final String server;
  final String uri;

  UserDeviceConfig({
    required this.authorizationUser,
    required this.displayName,
    required this.extension,
    required this.ha1,
    required this.realm,
    required this.server,
    required this.uri,
  });

  factory UserDeviceConfig.fromJson(Map<String, dynamic> json) {
    return UserDeviceConfig(
      authorizationUser: json['authorization_user'],
      displayName: json['display_name'],
      extension: json['extension'],
      ha1: json['ha1'],
      realm: json['realm'],
      server: json['server'],
      uri: json['uri'],
    );
  }
}
