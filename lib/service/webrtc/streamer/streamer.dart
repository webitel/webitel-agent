import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/capturer.dart';

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
  bool _isClosing = false;

  ScreenStreamer({
    required this.id,
    required this.peerSdp,
    required this.onClose,
    required this.logger,
    required this.onAccept,
    this.localStreams,
    this.localStream,
  });

  /// Factory method to build a streamer instance from a screen_share notification.
  /// This handles the initial resource cleanup and platform-specific capture.
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

    logger.info(
      '[ScreenStreamer] Initiating screen share for parent_id=$parentId',
    );

    // [CLEANUP] Ensure no stale streaming processes are running to avoid device conflicts
    await stopStereoAudioFFmpeg(FFmpegMode.streaming);

    // Initialize PeerConnection with ICE configuration (STUN/TURN)
    final pc = await createPeerConnection({
      'iceServers': AppConfig.instance.webrtcIceServers,
      'iceTransportPolicy': AppConfig.instance.webrtcIceTransportPolicy,
    });

    List<MediaStream>? localStreams;
    MediaStream? localStream;

    try {
      // [MEDIA_CAPTURE] Execute platform-specific screen and audio capture
      if (Platform.isWindows) {
        logger.debug(
          '[ScreenStreamer] Platform: Windows. Starting multi-screen FFmpeg capture.',
        );
        localStreams = await captureAllDesktopScreensWindows(
          FFmpegMode.streaming,
          pc,
        );
      } else {
        logger.debug(
          '[ScreenStreamer] Platform: macOS/Linux. Using standard media devices.',
        );
        localStream = await captureDesktopScreen();
        if (localStream == null) {
          throw Exception('Failed to obtain local media stream');
        }
      }

      final streamer = ScreenStreamer(
        id: parentId,
        peerSdp: sdp,
        logger: logger,
        localStreams: localStreams,
        localStream: localStream,
        onClose: onClose,
        onAccept: onAccept,
      );

      // Start the WebRTC handshake process (Offer -> Answer)
      await streamer._init(pc: pc);

      final answer = await streamer.localDescription;
      if (answer != null) {
        // [SDP_DIAGNOSTICS] Verify if the Answer contains video media sections
        final hasVideo = answer.sdp?.contains('m=video');
        logger.info(
          '[ScreenStreamer] SDP Answer generated. Video detected: $hasVideo',
        );

        await onAccept('ss_accept', {
          'id': notif['id'],
          'sdp': answer.sdp,
          'to_user_id': fromUserId,
          'sock_id': sockId,
          'session_id': parentId,
        });
      }

      return streamer;
    } catch (e, st) {
      logger.error(
        '[ScreenStreamer] Critical failure during factory initialization',
        e,
        st,
      );
      pc.close();
      pc.dispose();
      rethrow;
    }
  }

  /// Internal initialization of the PeerConnection and track management
  Future<void> _init({required RTCPeerConnection pc}) async {
    _pc = pc;

    try {
      // [MONITOR] Track connection state changes for debugging
      _pc!.onConnectionState = (state) {
        logger.debug('[ScreenStreamer] Connection State Change: ${state.name}');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            !_isClosing) {
          close('PeerConnectionStateFailed');
        }
      };

      _pc!.onIceConnectionState = (state) {
        logger.debug('[ScreenStreamer] ICE Connection State: ${state.name}');
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected &&
            !_isClosing) {
          close('IceConnectionDisconnected');
        }
      };

      _pc!.onSignalingState = (state) {
        logger.debug('[ScreenStreamer] Signaling State: ${state.name}');
      };

      // [SDP_HANDSHAKE] Step 1: Set Remote Offer from signaling server
      await _pc!.setRemoteDescription(RTCSessionDescription(peerSdp, 'offer'));
      logger.debug(
        '[ScreenStreamer] Remote description (offer) set successfully',
      );

      // [TRACK_MANAGEMENT] Attach captured streams to the PeerConnection
      if (Platform.isWindows && localStreams != null) {
        for (final stream in localStreams!) {
          for (final track in stream.getTracks()) {
            logger.debug(
              '[ScreenStreamer] Attaching track: kind=${track.kind}, id=${track.id}, enabled=${track.enabled}',
            );
            await _pc!.addTrack(track, stream);
          }
        }
      } else if (localStream != null) {
        for (final track in localStream!.getTracks()) {
          logger.debug(
            '[ScreenStreamer] Attaching track: kind=${track.kind}, id=${track.id}',
          );
          await _pc!.addTrack(track, localStream!);
        }
      }

      // [SDP_HANDSHAKE] Step 2: Create and set Local Answer
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      logger.debug(
        '[ScreenStreamer] Local description (answer) set successfully',
      );

      // [ICE_GATHERING] Wait for candidates to be gathered before sending SDP to avoid NAT issues
      await _waitForIceGatheringComplete(_pc!);

      logger.info('[ScreenStreamer] WebRTC Handshake procedure finalized');
    } catch (e, st) {
      logger.error('[ScreenStreamer] Handshake initialization failed:', e, st);
      close('HandshakeError: $e');
    }
  }

  /// Blocks until ICE gathering is complete or timeout is reached (approx 3 seconds)
  Future<void> _waitForIceGatheringComplete(RTCPeerConnection pc) async {
    int waitCount = 0;
    while (pc.iceGatheringState !=
            RTCIceGatheringState.RTCIceGatheringStateComplete &&
        waitCount < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitCount++;
    }
    logger.debug(
      '[ScreenStreamer] ICE Gathering finished with state: ${pc.iceGatheringState.toString()} after ${waitCount * 100}ms',
    );

    if (waitCount >= 30) {
      logger.warn(
        '[ScreenStreamer] ICE gathering timed out; sending partial SDP candidates.',
      );
    }
  }

  Future<RTCSessionDescription?> get localDescription async {
    return await _pc?.getLocalDescription();
  }

  /// Public method to terminate the stream and cleanup all hardware/network resources
  void close(String reason) {
    if (_isClosing) return;
    _isClosing = true;

    logger.warn('[ScreenStreamer] Shutting down session. Reason: $reason');
    _cleanupInternal();
    onClose();
  }

  /// Internal resource teardown: FFmpeg, MediaTracks, and PeerConnection
  void _cleanupInternal() {
    // 1. Kill the audio mixing/streaming process
    stopStereoAudioFFmpeg(FFmpegMode.streaming);

    try {
      // 2. Stop and dispose all active media tracks to release camera/mic/screen handles
      if (localStreams != null) {
        for (final s in localStreams!) {
          for (final t in s.getTracks()) {
            t.stop();
            logger.debug('[ScreenStreamer] Stopped track: ${t.id}');
          }
          s.dispose();
        }
      }

      if (localStream != null) {
        for (final t in localStream!.getTracks()) {
          t.stop();
        }
        localStream!.dispose();
      }

      // 3. Close the WebRTC socket/connection
      if (_pc != null) {
        _pc!.close();
        _pc!.dispose();
        _pc = null;
      }

      logger.info('[ScreenStreamer] Clean teardown successful');
    } catch (e) {
      logger.error('[ScreenStreamer] Error during teardown sequence:', e);
    }
  }
}
