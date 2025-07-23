import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:webitel_agent_flutter/logger.dart';

Future<RTCSessionDescription> sendSDPToServer({
  required String url,
  required String token,
  required RTCSessionDescription offer,
  required String id,
}) async {
  final payload = {
    'type': offer.type,
    'sdp_offer': offer.sdp,
    'uuid': id,
    'name': DateTime.now().toIso8601String(),
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
    logger.info('[Signaling] Received SDP answer');
    return RTCSessionDescription(json['sdp_answer'], 'answer');
  } catch (e, stack) {
    logger.error('[Signaling] Exception during SDP exchange: $e', stack);
    rethrow;
  }
}
