import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/common/webrtc/capturer.dart';

typedef OnReceiverClosed = void Function();
typedef OnAccept =
    Future<void> Function(String event, Map<String, dynamic> payload);

class ScreenStreamer {
  final String id;
  final String peerSdp;
  final OnReceiverClosed onClose;
  final LoggerService logger;
  final List<MediaStream>? localStreams;
  final MediaStream? localStream;
  final OnAccept onAccept;

  RTCPeerConnection? _pc;

  ScreenStreamer({
    required this.id,
    required this.peerSdp,
    required this.onClose,
    required this.logger,
    required this.onAccept,
    this.localStreams,
    this.localStream,
  });

  /// Factory method to build from screen_share notification
  static Future<ScreenStreamer> fromNotification({
    required Map<String, dynamic> notif,
    required LoggerService logger,
    required OnReceiverClosed onClose,
    required OnAccept onAccept,
  }) async {
    final body = notif['body'] as Map<String, dynamic>?;
    final sdp = body?['sdp'] as String?;
    final parentId = body?['parent_id'] as String?;
    final fromUserId = body?['from_user_id'];
    final sockId = body?['sock_id'];

    if (sdp == null || parentId == null) {
      throw ArgumentError(
        'Invalid screen_share notification: missing sdp or parentId',
      );
    }

    logger.info('[ScreenStreamer] screen_share received, parent_id=$parentId');

    final pc = await createPeerConnection({
      'iceServers': AppConfig.instance.webrtcIceServers,
      'iceTransportPolicy': AppConfig.instance.webrtcIceTransportPolicy,
    });

    List<MediaStream>? localStreams;
    MediaStream? localStream;

    if (Platform.isWindows) {
      localStreams = await captureAllDesktopScreensWindows(
        FFmpegMode.streaming,
        pc,
      );
    } else {
      localStream = await captureDesktopScreen();
      if (localStream != null) {
        for (final track in localStream.getTracks()) {
          await pc.addTrack(track, localStream);
        }
      }
    }

    final screenStreamer = ScreenStreamer(
      id: parentId,
      peerSdp: sdp,
      logger: logger,
      localStreams: localStreams,
      localStream: localStream,
      onClose: onClose,
      onAccept: onAccept,
    );

    await screenStreamer._init(pc: pc);

    final answer = await screenStreamer.localDescription;
    if (answer != null) {
      await onAccept('ss_accept', {
        'id': notif['id'],
        'sdp': answer.sdp,
        'to_user_id': fromUserId,
        'sock_id': sockId,
        'session_id': parentId,
      });
    }

    return screenStreamer;
  }

  Future<void> _init({required RTCPeerConnection pc}) async {
    _pc = pc;

    try {
      _pc!.onSignalingState = (state) {
        logger.debug('[ScreenStreamer] Signaling state: $state');
      };
      _pc!.onIceGatheringState = (state) {
        logger.debug('[ScreenStreamer] ICE gathering state: $state');
      };
      _pc!.onConnectionState = (state) async {
        logger.debug('[ScreenStreamer] Peer connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          logger.warn(
            '[ScreenStreamer] Peer connection failed/closed, restarting ICE...',
          );

          await _pc?.restartIce();
        }
      };
      _pc!.onIceConnectionState = (state) async {
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          await stopStereoAudioFFmpeg(FFmpegMode.streaming);
        }
        logger.debug('[ScreenStreamer] ICE connection state: $state');
      };

      await _pc!.setRemoteDescription(RTCSessionDescription(peerSdp, 'offer'));
      logger.info('[ScreenStreamer] Remote SDP set:\n$peerSdp');

      if (Platform.isWindows) {
        if (localStreams != null && localStreams!.isNotEmpty) {
          for (final stream in localStreams!) {
            for (final track in stream.getTracks()) {
              await _pc!.addTrack(track, stream);
              logger.debug(
                '[ScreenStreamer] Added Windows track: ${track.kind}',
              );
            }
          }
        } else {
          logger.warn('[ScreenStreamer] No local streams found for Windows');
        }
      } else {
        if (localStream != null) {
          for (final track in localStream!.getTracks()) {
            await _pc!.addTrack(track, localStream!);
            logger.debug('[ScreenStreamer] Added macOS track: ${track.kind}');
          }
        } else {
          logger.warn('[ScreenStreamer] No local stream available');
        }
      }

      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      logger.info(
        '[ScreenStreamer] Local SDP answer set:\n${answer.sdp?.trim() ?? "<empty>"}',
      );

      await waitForIceGatheringComplete(_pc!);
    } catch (e, st) {
      logger.error('[ScreenStreamer] Failed to start:', e, st);
      close('Exception during start: $e');
    }
  }

  Future<void> waitForIceGatheringComplete(
    RTCPeerConnection pc, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final start = DateTime.now();
    while (pc.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (DateTime.now().difference(start) > timeout) {
        throw TimeoutException('ICE gathering did not complete in time');
      }
    }
  }

  Future<RTCSessionDescription?>? get localDescription async {
    return await _pc?.getLocalDescription();
  }

  void close(String reason) {
    logger.warn('[ScreenStreamer] Closing: $reason');
    stopStereoAudioFFmpeg(FFmpegMode.streaming);

    try {
      if (localStreams != null && localStreams!.isNotEmpty) {
        for (final stream in localStreams!) {
          for (final track in stream.getTracks()) {
            try {
              track.stop();
              logger.debug('[ScreenStreamer] Stopped track: ${track.kind}');
            } catch (e, st) {
              logger.error('[ScreenStreamer] Error stopping track:', e, st);
            }
          }
          try {
            stream.dispose();
            logger.debug('[ScreenStreamer] Disposed stream');
          } catch (e, st) {
            logger.error('[ScreenStreamer] Error disposing stream:', e, st);
          }
        }
      }

      if (localStream != null) {
        for (final track in localStream!.getTracks()) {
          try {
            track.stop();
            logger.debug('[ScreenStreamer] Stopped track: ${track.kind}');
          } catch (e, st) {
            logger.error('[ScreenStreamer] Error stopping track:', e, st);
          }
        }
        try {
          localStream!.dispose();
          logger.debug('[ScreenStreamer] Disposed stream');
        } catch (e, st) {
          logger.error('[ScreenStreamer] Error disposing stream:', e, st);
        }
      }

      _pc?.close();
      _pc?.dispose();
      _pc = null;

      logger.info('[ScreenStreamer] Resources released successfully');
    } catch (e, st) {
      logger.error('[ScreenStreamer] Error during close:', e, st);
    }

    onClose();
  }
}
