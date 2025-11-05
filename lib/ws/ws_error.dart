class SocketError implements Exception {
  final String id;
  final String status;
  final String detail;
  final int code;

  SocketError({
    required this.id,
    required this.status,
    required this.detail,
    required this.code,
  });

  factory SocketError.fromJson(Map<String, dynamic> json) {
    return SocketError(
      id: json['id'] ?? 'unknown_error',
      status: json['status'] ?? 'Unknown',
      detail: json['detail'] ?? 'No details',
      code: json['code'] ?? -1,
    );
  }

  @override
  String toString() => '[$code] $status: $detail';

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'id': id,
      'status': status,
      'detail': detail,
    };
  }
}
