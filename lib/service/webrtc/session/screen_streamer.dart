import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/service/webrtc/core/capturer.dart';

typedef OnReceiverClosed = void Function();
typedef OnAccept =
    Future<void> Function(String event, Map<String, dynamic> payload);

class ScreenStreamer {
  final String id;
  final String peerSdp;
  final List<Map<String, dynamic>> iceServers;
  final OnReceiverClosed onClose;
  final LoggerService logger;
  final MediaStream? localStream;
  final OnAccept onAccept;

  RTCPeerConnection? _pc;

  ScreenStreamer({
    required this.id,
    required this.peerSdp,
    required this.iceServers,
    required this.onClose,
    required this.logger,
    required this.onAccept,
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

    final localStream = await captureDesktopScreen();

    final screenStreamer = ScreenStreamer(
      id: parentId,
      peerSdp: sdp,
      iceServers: [],
      logger: logger,
      localStream: localStream,
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
        'iceTransportPolicy': 'all',
        'tcpCandidatePolicy': 'enabled',
      });

      // await _pc!.setConfiguration({
      //   'iceServers': iceServers,
      //   'sdpSemantics': 'unified-plan',
      // });

      logger.debug('[ScreenStreamer] Peer connection created');

      _pc!.onSignalingState = (RTCSignalingState state) {
        logger.debug('[ScreenStreamer] Signaling state: $state');
        if (state == RTCSignalingState.RTCSignalingStateClosed) {
          logger.warn(
            '[ScreenStreamer] Signaling state $state - closing connection',
          );
          close('Signaling $state');
        }
      };

      _pc?.onIceGatheringState = (RTCIceGatheringState state) {
        logger.debug('[ScreenStreamer] ICE gathering state: $state');
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          logger.info('[ScreenStreamer] ICE gathering complete');
        } else if (state ==
            RTCIceGatheringState.RTCIceGatheringStateGathering) {
          logger.info('[ScreenStreamer] ICE gathering in progress...');
        }
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

      // Handle ICE connection state changes
      _pc!.onIceConnectionState = (RTCIceConnectionState state) async {
        logger.debug('[ScreenStreamer] ICE connection state: $state');

        switch (state) {
          case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
            await _pc?.restartIce();
            break;
          case RTCIceConnectionState.RTCIceConnectionStateFailed:
            logger.error(
              '[ScreenStreamer] ICE state $state - closing connection',
            );
            close('ICE $state');
            break;
          case RTCIceConnectionState.RTCIceConnectionStateClosed:
            close('ICE $state');
            logger.warn('[ScreenStreamer] ICE connection closed manually');
            break;
          case RTCIceConnectionState.RTCIceConnectionStateConnected:
            logger.info('[ScreenStreamer] ICE connected');
            break;
          case RTCIceConnectionState.RTCIceConnectionStateCompleted:
            logger.info('[ScreenStreamer] ICE completed');
            break;
          default:
            break;
        }
      };

      // Set remote SDP
      await _pc!.setRemoteDescription(RTCSessionDescription(peerSdp, 'offer'));
      logger.info('[ScreenStreamer] Remote SDP offer set');

      // Add local tracks
      if (localStream != null) {
        for (final track in localStream!.getTracks()) {
          await _pc!.addTrack(track, localStream!);
          logger.debug('[ScreenStreamer] Added local track: ${track.kind}');
        }
      } else {
        logger.warn('[ScreenStreamer] No local stream to add');
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
      logger.error('[ScreenStreamer] Failed to start: $e');
      logger.debug(stack.toString());
      close('Exception during start: $e');
    }
  }

  Future<void> restartIceFlow() async {
    logger.info('[ScreenStreamer] Performing full ICE restart');

    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);

      logger.debug('[ScreenStreamer] Restart ICE offer created and set');

      await onAccept('ss_restart', {'id': id, 'sdp': offer.sdp});

      logger.info('[ScreenStreamer] ICE restart offer sent');
    } catch (e, stack) {
      logger.error('[ScreenStreamer] ICE restart failed: $e');
      logger.debug(stack.toString());
      close('ICE restart failed');
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
    _pc?.close();
    _pc?.dispose();
    _pc = null;
    localStream?.dispose();
    onClose();
  }
}
