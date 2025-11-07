import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/common/webrtc/capturer.dart';

typedef OnReceiverClosed = void Function();
typedef OnAccept =
    Future<void> Function(String event, Map<String, dynamic> payload);

class ScreenStreamer {
  final String id;
  final String peerSdp;
  final List<Map<String, dynamic>> iceServers;
  final OnReceiverClosed onClose;
  final LoggerService logger;
  final List<MediaStream>? localStreams;
  final OnAccept onAccept;

  RTCPeerConnection? _pc;

  ScreenStreamer({
    required this.id,
    required this.peerSdp,
    required this.iceServers,
    required this.onClose,
    required this.logger,
    required this.onAccept,
    this.localStreams,
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

    List<MediaStream>? localStreams;

    Platform.isWindows
        ? localStreams = await captureAllDesktopScreensWindows()
        : await captureAllDesktopScreensWindows();

    final screenStreamer = ScreenStreamer(
      id: parentId,
      peerSdp: sdp,
      iceServers: [],
      logger: logger,
      localStreams: localStreams,
      onClose: onClose,
      onAccept: onAccept,
    );

    await screenStreamer.start();

    final answer = await screenStreamer.localDescription;
    if (answer == null) {
      logger.error('[ScreenStreamer] localDescription is null after start()');
      return screenStreamer;
    }

    await onAccept('ss_accept', {
      'id': notif['id'],
      'sdp': answer.sdp,
      'to_user_id': fromUserId,
      'sock_id': sockId,
      'session_id': parentId,
    });

    return screenStreamer;
  }

  Future<void> start() async {
    logger.info('[ScreenStreamer] Starting peer connection for id: $id');

    try {
      // Create peer connection
      // In peer connection configuration:
      _pc = await createPeerConnection({
        'iceServers': iceServers,
        'iceConnectionReceivingTimeout': 15000,
      });

      logger.debug('[ScreenStreamer] Peer connection created');

      _pc!.onSignalingState = (RTCSignalingState state) {
        logger.debug('[ScreenStreamer] Signaling state: $state');
      };

      _pc?.onIceGatheringState = (RTCIceGatheringState state) {
        logger.debug('[ScreenStreamer] ICE gathering state: $state');
      };

      _pc!.onConnectionState = (RTCPeerConnectionState state) async {
        logger.debug('[ScreenStreamer] Peer connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          logger.warn(
            '[ScreenStreamer] Peer connection failed/closed, stopping stream...',
          );
          await _pc?.restartIce();
        }
      };

      _pc!.onIceConnectionState = (RTCIceConnectionState state) async {
        logger.debug('[ScreenStreamer] ICE connection state: $state');
      };

      // Set remote SDP
      await _pc!.setRemoteDescription(RTCSessionDescription(peerSdp, 'offer'));
      logger.info('[ScreenStreamer] Remote SDP offer set');

      // Add local tracks
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
        // macOS / others — беремо лише перший стрім
        if (localStreams != null && localStreams!.isNotEmpty) {
          final stream = localStreams!.first;
          for (final track in stream.getTracks()) {
            await _pc!.addTrack(track, stream);
            logger.debug('[ScreenStreamer] Added macOS track: ${track.kind}');
          }
        } else {
          logger.warn('[ScreenStreamer] No local stream available');
        }
      }
      // Create answer
      // In offer/answer options:
      final answer = await _pc!.createAnswer({});
      logger.debug('[ScreenStreamer] SDP answer created');

      // Set local SDP
      await _pc!.setLocalDescription(answer);
      logger.info('[ScreenStreamer] >>>>>>>>>>>>>>>>>>>> Local SDP answer set');

      await waitForIceGatheringComplete(_pc!);
    } catch (e, stack) {
      logger.error('[ScreenStreamer] Failed to start:', e, stack);
      logger.debug(stack.toString());
      close('Exception during start: $e');
    }
  }

  Future<void> waitForIceGatheringComplete(
    RTCPeerConnection pc, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final start = DateTime.now();

    while (pc.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await Future.delayed(const Duration(milliseconds: 100));
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
        localStreams!.clear();
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
