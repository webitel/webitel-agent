import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_agent_flutter/logger.dart';

typedef OnTrackReceived = void Function(MediaStream stream);
typedef OnReceiverClosed = void Function();

class ScreenStreamer {
  final String id;
  final String peerSdp;
  final List<Map<String, dynamic>> iceServers;
  final OnTrackReceived onTrack;
  final OnReceiverClosed onClose;
  final LoggerService logger;
  final MediaStream? localStream;

  RTCPeerConnection? _pc;
  Timer? _keepAliveTimer;

  ScreenStreamer({
    required this.id,
    required this.peerSdp,
    required this.iceServers,
    required this.onTrack,
    required this.onClose,
    required this.logger,
    this.localStream,
  });

  Future<void> start() async {
    logger.info('[ScreenStreamer] Starting peer connection for id: $id');

    try {
      // Create peer connection
      // In peer connection configuration:
      _pc = await createPeerConnection({
        'iceServers': iceServers,
        'iceTransportPolicy': 'all',
        'iceCandidatePoolSize': 5,
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
      });

      await _pc!.setConfiguration({
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
        'bweConfiguration': {
          'minBitrate': 500000,
          'maxBitrate': 3000000,
          'startBitrate': 1000000,
        },
      });

      logger.debug('[ScreenStreamer] Peer connection created');

      // Handle ICE connection state changes
      _pc!.onIceConnectionState = (RTCIceConnectionState state) {
        logger.debug('[ScreenStreamer] ICE connection state: $state');

        switch (state) {
          case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
            _restartIce();
          case RTCIceConnectionState.RTCIceConnectionStateFailed:
            logger.error(
              '[ScreenStreamer] ICE state $state - closing connection',
            );
            // close('ICE $state');
            _restartIce();
            break;
          case RTCIceConnectionState.RTCIceConnectionStateClosed:
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
      final answer = await _pc!.createAnswer({'iceRestart': true});
      logger.debug('[ScreenStreamer] SDP answer created');

      // Set local SDP
      await _pc!.setLocalDescription(answer);
      logger.info('[ScreenStreamer] Local SDP answer set');

      // Optional: Timeout to check ICE not stuck
      Future.delayed(Duration(seconds: 30), () async {
        if (_pc != null &&
            _pc!.iceConnectionState !=
                RTCIceConnectionState.RTCIceConnectionStateConnected &&
            _pc!.iceConnectionState !=
                RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          logger.error('[ScreenStreamer] ICE timeout - force closing');
          close('ICE timeout');
        }
      });
    } catch (e, stack) {
      logger.error('[ScreenStreamer] Failed to start: $e');
      logger.debug(stack.toString());
      close('Exception during start: $e');
    }
  }

  void _restartIce() async {
    try {
      await _pc!.restartIce();
      logger.info('ICE restart triggered');
    } catch (e) {
      logger.error('ICE restart failed: $e');
    }
  }

  Future<void> restartSession() async {
    logger.info('[ScreenStreamer] Restarting session for id: $id');
    await _pc?.close();
    _pc = null;

    // Optional: fetch a new offer from the signaling server
    // If peerSdp changes dynamically, you'll need to request a new one here

    await start(); // Recreate everything from scratch
  }

  // Future<void> start() async {
  //   logger.info('[ScreenStreamer] Starting peer connection');
  //
  //   // Create peer connection
  //   _pc = await createPeerConnection({'iceServers': iceServers});
  //
  //   // Set remote SDP offer
  //   await _pc!.setRemoteDescription(RTCSessionDescription(peerSdp, 'offer'));
  //   logger.info('[ScreenStreamer] Remote SDP offer set');
  //
  //   // Add local tracks (e.g., desktop screen)
  //   if (localStream != null) {
  //     for (var track in localStream!.getTracks()) {
  //       await _pc!.addTrack(track, localStream!);
  //       logger.info('[ScreenStreamer] Added local track: ${track.kind}');
  //     }
  //   }
  //
  //   _pc!.onIceConnectionState = (state) {
  //     logger.debug('[ScreenStreamer] ICE connection state: $state');
  //     if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
  //         state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
  //       logger.warn(
  //         '[ScreenStreamer] ICE disconnected/failed, closing receiver...',
  //       );
  //       close('ICE disconnected/failed');
  //     }
  //   };
  //
  //   // Create and set local SDP answer
  //   final RTCSessionDescription answer = await _pc!.createAnswer();
  //   await _pc!.setLocalDescription(answer);
  //   logger.info('[ScreenStreamer] Created and set local SDP answer');
  // }

  Future<RTCSessionDescription?>? get localDescription =>
      _pc?.getLocalDescription();

  void close(String reason) {
    logger.warn('[ScreenStreamer] Closing: $reason');
    _pc?.close();
    _pc = null;
    localStream?.dispose();
    onClose();
  }
}
