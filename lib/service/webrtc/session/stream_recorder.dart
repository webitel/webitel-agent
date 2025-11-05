import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/service/webrtc/core/capturer.dart';
import 'package:webitel_agent_flutter/service/webrtc/core/peer_connection.dart';
import 'package:webitel_agent_flutter/service/webrtc/core/signaling.dart';

class StreamRecorder {
  final String callID;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;

  RTCPeerConnection? pc;
  List<MediaStream> streams = [];
  String? _sessionID;

  bool get isStreaming => pc != null && streams.isNotEmpty;

  StreamRecorder({
    required this.callID,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
  });

  Future<void> start() async {
    logger.info('[StreamRecorder] Starting stream sender for call $callID');

    pc = await createPeerConnectionWithConfig(iceServers);

    pc!.onIceConnectionState = (state) {
      logger.debug('[StreamRecorder] ICE connection state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logger.warn(
          '[StreamRecorder] ICE disconnected/failed, stopping stream...',
        );
        stop();
      }
    };

    if (Platform.isWindows) {
      logger.info(
        '[StreamRecorder] Windows platform detected — capturing all monitors',
      );
      streams = await captureAllDesktopScreensWindows();

      if (streams.isEmpty) {
        logger.error('[StreamRecorder] Could not capture any screen');
        throw Exception('Screen capture failed');
      }

      for (final s in streams) {
        for (var track in s.getTracks()) {
          final settings = track.getSettings();

          logger.debug(
            '[Capturer] Track settings: '
            'width=${settings['width']}, '
            'height=${settings['height']}, '
            'frameRate=${settings['frameRate']}',
          );

          pc!.addTrack(track, s);
        }
      }
    } else {
      logger.info(
        '[StreamRecorder] Non-Windows platform — capturing single screen',
      );
      final stream = await captureDesktopScreen();

      if (stream == null) {
        logger.error('[StreamRecorder] Could not capture screen');
        throw Exception('Screen capture failed');
      }

      streams = [stream];

      for (var track in stream.getTracks()) {
        final settings = track.getSettings();

        logger.debug(
          '[Capturer] Track settings: '
          'width=${settings['width']}, '
          'height=${settings['height']}, '
          'frameRate=${settings['frameRate']}',
        );

        pc!.addTrack(track, stream);
      }
    }

    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);
    logger.debug('[StreamRecorder] Created SDP offer');

    final localDescription = await pc!.getLocalDescription();
    if (localDescription == null) {
      throw Exception('Local SDP is null');
    }

    final response = await sendSDPToServer(
      url: sdpResolverUrl,
      token: token,
      offer: localDescription,
      id: callID,
    );

    _sessionID = response.streamId;
    await pc!.setRemoteDescription(response.answer);
    logger.info(
      '[StreamRecorder] Set remote SDP, streaming started (id=$_sessionID)',
    );
  }

  Future<void> stop() async {
    logger.info('[StreamRecorder] Stopping stream sender...');

    if (_sessionID != null) {
      final fullStopUrl = '$sdpResolverUrl/$_sessionID';
      try {
        await stopStreamOnServer(
          url: fullStopUrl,
          token: token,
          id: _sessionID ?? '',
        );
      } catch (e) {
        logger.warn('[StreamRecorder] Failed to stop stream on server: $e');
      }
    } else {
      logger.warn(
        '[StreamRecorder] No stream ID received, skipping server stop',
      );
    }

    for (final s in streams) {
      for (var t in s.getTracks()) {
        logger.debug('[StreamRecorder] Stopping track: ${t.kind}');
        t.stop();
      }
    }

    streams.clear();

    if (pc != null) {
      await pc!.close();
      logger.debug('[StreamRecorder] Closed peer connection');
      pc = null;
    }
  }
}
