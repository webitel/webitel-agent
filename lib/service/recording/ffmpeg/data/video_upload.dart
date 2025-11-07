import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/recording/ffmpeg/data/retry.dart';

class VideoUploadService {
  final String baseUrl;
  final String agentToken;

  VideoUploadService({required this.baseUrl, required this.agentToken});

  Future<bool> uploadWithRetry({
    required String filePath,
    required String callId,
    required String channel,
    DateTime? startTime,
  }) async {
    return retry(
      () => _upload(filePath, callId, channel, startTime),
      maxRetries: 3,
    );
  }

  Future<bool> _upload(
    String filePath,
    String callId,
    String channel,
    DateTime? startTime,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    final query = {
      'channel': channel,
      'access_token': agentToken,
      'thumbnail': 'true',
    };

    if (startTime != null) {
      query['start_time'] = '${startTime.millisecondsSinceEpoch}';
      query['end_time'] = '${DateTime.now().millisecondsSinceEpoch}';
    }

    final uri = Uri.parse(
      '$baseUrl/api/storage/file/$callId/upload',
    ).replace(queryParameters: query);

    final mimeType = lookupMimeType(filePath) ?? 'video/mp4';
    final parts = mimeType.split('/');

    final req = http.MultipartRequest('POST', uri)
      ..files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          contentType: MediaType(parts[0], parts[1]),
        ),
      );

    final res = await req.send();
    logger.info('Uploading video → ${res.statusCode}');

    return res.statusCode == 200 || res.statusCode == 201;
  }
}
