import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';

/// Sends an SDP offer to the signaling server and returns the answer with a stream ID.
/// This function coordinates the WebRTC handshake and defines the recording filename.
Future<({RTCSessionDescription answer, String streamId})> sendSDPToServer({
  required String url,
  required String token,
  required RTCSessionDescription offer,
  required String id,
  required IStorageService storage,
}) async {
  // Retrieve the agent ID from local storage for identification
  final agentId = await storage.readAgentId() ?? 0;

  final now = DateTime.now();

  /// Standardized timestamp format: YYYYMMDD_HHMMSS
  /// Matches the format used in ScreenshotSenderService exactly.
  final String timestamp =
      "${now.year}"
      "${now.month.toString().padLeft(2, '0')}"
      "${now.day.toString().padLeft(2, '0')}_"
      "${now.hour.toString().padLeft(2, '0')}"
      "${now.minute.toString().padLeft(2, '0')}"
      "${now.second.toString().padLeft(2, '0')}";

  // Final filename format: scr_ss_[agentId]_[timestamp].mp4
  // Using 'scr_ss' prefix to match manual/auto screenshot naming convention.
  final fileName = 'scr_vc_${agentId}_$timestamp.mp4';

  final payload = {
    'type': offer.type,
    'sdp_offer': offer.sdp,
    'uuid': id,
    'name': fileName,
  };

  try {
    logger.debug('[Signaling] Sending SDP offer for file: $fileName to $url');

    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'X-Webitel-Access': token,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      logger.error(
        '[Signaling] SDP exchange failed (${response.statusCode}): ${response.body}',
      );
      throw Exception(
        'SDP exchange failed with status: ${response.statusCode}',
      );
    }

    final json = jsonDecode(response.body);
    logger.info('[Signaling] SDP answer received. Stream ID: ${json['id']}');

    return (
      answer: RTCSessionDescription(json['sdp_answer'], 'answer'),
      streamId: json['id'] as String,
    );
  } catch (e, st) {
    logger.error('[Signaling] Exception during SDP exchange', e, st);
    rethrow;
  }
}

/// Notifies the signaling server to stop and finalize the stream.
/// This ensures the recorded video file is properly closed and saved on the server.
Future<void> stopStreamOnServer({
  required String url,
  required String id,
  required String token,
}) async {
  try {
    logger.debug('[Signaling] Sending DELETE to finalize stream session: $id');

    final response = await http
        .delete(Uri.parse(url), headers: {'X-Webitel-Access': token})
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      logger.warn(
        '[Signaling] Server failed to stop stream (${response.statusCode}): ${response.body}',
      );
      throw Exception('Failed to stop stream on server');
    }

    logger.info('[Signaling] Stream $id successfully stopped on server.');
  } catch (e, st) {
    logger.error('[Signaling] Exception during stream stop', e, st);
    rethrow;
  }
}
