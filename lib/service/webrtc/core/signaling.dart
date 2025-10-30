import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/storage.dart';

Future<({RTCSessionDescription answer, String streamId})> sendSDPToServer({
  required String url,
  required String token,
  required RTCSessionDescription offer,
  required String id,
}) async {
  final agentId = await SecureStorageService().readAgentId() ?? 'unknown_user';
  final now = DateTime.now();

  final date =
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final time =
      '${now.hour.toString().padLeft(2, '0')}-'
      '${now.minute.toString().padLeft(2, '0')}-'
      '${now.second.toString().padLeft(2, '0')}';

  // Example: recording_123_2024-06-15_14-30-45.mp4
  final fileName = 'recording_ss_${agentId}_${date}_$time.mp4';

  final payload = {
    'type': offer.type,
    'sdp_offer': offer.sdp,
    'uuid': id,
    'name': fileName,
  };

  try {
    logger.debug('[Signaling] Sending SDP offer to $url...');
    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'X-Webitel-Access': token},
      body: jsonEncode(payload),
    );

    logger.debug('[Signaling] SDP response status: ${response.statusCode}');
    if (response.statusCode != 200) {
      logger.error('[Signaling] SDP exchange failed: ${response.body}');
      throw Exception('SDP exchange failed');
    }

    final json = jsonDecode(response.body);
    logger.info('[Signaling] Received SDP answer and stream ID');

    return (
      answer: RTCSessionDescription(json['sdp_answer'], 'answer'),
      streamId: json['id'] as String,
    );
  } catch (e, stack) {
    logger.error('[Signaling] Exception during SDP exchange: $e', stack);
    rethrow;
  }
}

Future<void> stopStreamOnServer({
  required String url,
  required String id,
  required String token,
}) async {
  try {
    logger.debug('[Signaling] Sending DELETE to $url...');
    final response = await http.delete(
      Uri.parse(url),
      headers: {'X-Webitel-Access': token},
    );

    logger.debug('[Signaling] DELETE response: ${response.statusCode}');
    if (response.statusCode != 200) {
      logger.warn(
        '[Signaling] Failed to stop stream on server: ${response.body}',
      );
      throw Exception('Failed to stop stream on server');
    }

    logger.info('[Signaling] Stream successfully stopped on server');
  } catch (e, stack) {
    logger.error('[Signaling] Exception during stream stop: $e', stack);
    rethrow;
  }
}
