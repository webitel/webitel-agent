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

    // [GUARD] Ensure no stale streaming processes are running before starting new ones
    await stopStereoAudioFFmpeg(FFmpegMode.streaming);

    // Create PeerConnection with configured ICE servers
    final pc = await createPeerConnection({
      'iceServers': AppConfig.instance.webrtcIceServers,
      'iceTransportPolicy': AppConfig.instance.webrtcIceTransportPolicy,
    });

    List<MediaStream>? localStreams;
    MediaStream? localStream;

    try {
      // [LOGIC] Capture screens based on host platform
      if (Platform.isWindows) {
        localStreams = await captureAllDesktopScreensWindows(
          FFmpegMode.streaming,
          pc,
        );
      } else {
        localStream = await captureDesktopScreen();
        if (localStream == null) {
          throw Exception('Failed to capture local screen');
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

      await streamer._init(pc: pc);

      final answer = await streamer.localDescription;
      if (answer != null) {
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
      logger.error('[ScreenStreamer] Factory build failed', e, st);
      // Immediate cleanup on failure
      pc.close();
      pc.dispose();
      rethrow;
    }
  }

  Future<void> _init({required RTCPeerConnection pc}) async {
    _pc = pc;

    try {
      _pc!.onConnectionState = (state) {
        logger.debug('[ScreenStreamer] Connection state: ${state.name}');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            !_isClosing) {
          logger.warn('[ScreenStreamer] Connection failed, cleaning up');
          close('PeerConnectionStateFailed');
        }
      };

      _pc!.onIceConnectionState = (state) {
        logger.debug('[ScreenStreamer] ICE state: ${state.name}');
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected &&
            !_isClosing) {
          // Note: In streaming mode, we often prefer to close and let the admin reconnect
          close('IceConnectionDisconnected');
        }
      };

      // [PROTOCOL] Set Remote Offer from the signaling message
      await _pc!.setRemoteDescription(RTCSessionDescription(peerSdp, 'offer'));

      // [PROTOCOL] Attach local tracks to PC
      if (Platform.isWindows && localStreams != null) {
        for (final stream in localStreams!) {
          for (final track in stream.getTracks()) {
            await _pc!.addTrack(track, stream);
          }
        }
      } else if (localStream != null) {
        for (final track in localStream!.getTracks()) {
          await _pc!.addTrack(track, localStream!);
        }
      }

      // [PROTOCOL] Create Local Answer
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      // [WAIT] Wait for ICE gathering to complete (crucial for NAT traversal)
      await _waitForIceGatheringComplete(_pc!);

      logger.info('[ScreenStreamer] Protocol handshake complete');
    } catch (e, st) {
      logger.error('[ScreenStreamer] Handshake initialization failed:', e, st);
      close('HandshakeError: $e');
    }
  }

  Future<void> _waitForIceGatheringComplete(RTCPeerConnection pc) async {
    int waitCount = 0;
    while (pc.iceGatheringState !=
            RTCIceGatheringState.RTCIceGatheringStateComplete &&
        waitCount < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitCount++;
    }
    if (waitCount >= 30) {
      logger.warn(
        '[ScreenStreamer] ICE gathering reached timeout, sending partial SDP',
      );
    }
  }

  Future<RTCSessionDescription?> get localDescription async {
    return await _pc?.getLocalDescription();
  }

  /// Public close method to release all resources
  void close(String reason) {
    if (_isClosing) return;
    _isClosing = true;

    logger.warn('[ScreenStreamer] Closing session. Reason: $reason');
    _cleanupInternal();
    onClose();
  }

  /// [LOGIC] Centralized resource teardown
  void _cleanupInternal() {
    // 1. Terminate audio streaming FFmpeg process
    stopStereoAudioFFmpeg(FFmpegMode.streaming);

    try {
      // 2. Explicitly stop and dispose all media tracks
      if (localStreams != null) {
        for (final s in localStreams!) {
          for (final t in s.getTracks()) {
            t.stop();
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

      // 3. Close the WebRTC PeerConnection
      if (_pc != null) {
        _pc!.close();
        _pc!.dispose();
        _pc = null;
      }

      logger.info('[ScreenStreamer] Teardown finished');
    } catch (e) {
      logger.error('[ScreenStreamer] Cleanup error:', e);
    }
  }
}
