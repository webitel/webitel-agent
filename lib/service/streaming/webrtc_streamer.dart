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
  Timer? _statsTimer;

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

          if (AppConfig.instance.webrtcEnableMetrics) {
            /// Stop metrics
            _statsTimer?.cancel();
            _statsTimer = null;
          }
          await _pc?.restartIce();
        }
      };
      _pc!.onIceConnectionState = (state) async {
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          await stopStereoAudioFFmpeg(FFmpegMode.streaming);
          if (AppConfig.instance.webrtcEnableMetrics) {
            /// Stop metrics
            _statsTimer?.cancel();
            _statsTimer = null;
          }
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

      if (AppConfig.instance.webrtcEnableMetrics) {
        // START METRICS
        _startMetricsMonitor();
      }
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

  /// METRICS MONITOR
  void _startMetricsMonitor() {
    _statsTimer?.cancel();

    // --- PERSISTENT STATE FOR CALCULATIONS ---
    // We need to store previous cumulative values to calculate 'rate' metrics (per second).
    int? prevBytesSent = 0;
    double? prevTotalEncodeTime = 0.0;
    int? prevFramesEncoded = 0;
    DateTime? prevTime = DateTime.now();
    // ------------------------------------------

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final pc = _pc;
      if (pc == null) return;

      // ----------------------------
      // METRICS - Initialize for each interval
      // ----------------------------
      double? fps;
      int? width;
      int? height;

      // outbound-rtp video
      int? framesSent;
      int? framesEncoded;
      double? encodeTimeTotal;
      int? keyFrames;
      int? packetsSent;
      int? bytesSent;
      int? nack;
      int? pli;
      int? fir;
      int? targetBitrate; // The bitrate requested by the encoder/sender

      // candidate-pair & transport
      double? rtt;
      int? bytesReceived;
      bool? writable;
      bool? nominated;
      String? iceState;

      try {
        final reports = await pc.getStats();

        for (final report in reports) {
          switch (report.type) {
            // -------------------------------------------
            // MEDIA SOURCE — FPS + RESOLUTION (Source data)
            // -------------------------------------------
            case 'media-source':
              if (report.values['kind'] == 'video') {
                fps = (report.values['framesPerSecond'] as num?)?.toDouble();
                width = report.values['width'];
                height = report.values['height'];
              }
              break;

            // -------------------------------------------
            // TRACK (Sender/Receiver data)
            // -------------------------------------------
            case 'track':
              if (report.values['kind'] == 'video') {
                // Prefer 'framesSentPerSecond' from track report if available (more reliable for actual sending rate)
                fps =
                    (report.values['framesSentPerSecond'] as num?)
                        ?.toDouble() ??
                    fps;
              }
              break;

            // -------------------------------------------
            // OUTBOUND RTP (Sending stats, encoding performance)
            // FIX: Changed 'mediaType' to 'kind' based on log inspection.
            // -------------------------------------------
            case 'outbound-rtp':
              if (report.values['kind'] == 'video') {
                // FIXED FILTERING
                framesSent = report.values['framesSent'];
                framesEncoded = report.values['framesEncoded'];
                encodeTimeTotal =
                    (report.values['totalEncodeTime'] as num?)?.toDouble();
                keyFrames = report.values['keyFramesEncoded'];
                packetsSent = report.values['packetsSent'];
                bytesSent = report.values['bytesSent'];
                nack = report.values['nackCount'];
                pli = report.values['pliCount'];
                fir = report.values['firCount'];
                // Cast targetBitrate safely as it might be a double in the report
                targetBitrate =
                    (report.values['targetBitrate'] as num?)?.toInt();
              }
              break;

            // -------------------------------------------
            // CANDIDATE PAIR — RTT + network health
            // -------------------------------------------
            case 'candidate-pair':
              // Prioritize the stats from the 'nominated' or 'succeeded' pair.
              if (report.values['state'] == 'succeeded' &&
                  (report.values['nominated'] == true || rtt == null)) {
                rtt =
                    (report.values['currentRoundTripTime'] as num?)?.toDouble();

                // Note: bytesReceived from candidate-pair is the total for the transport layer,
                // which is a good proxy for overall received data.
                bytesReceived = report.values['bytesReceived'];
                writable = report.values['writable'];
                nominated = report.values['nominated'];
                iceState = report.values['state'];
              }
              break;

            // -------------------------------------------
            // TRANSPORT (Fallback for reliable bytesReceived)
            // -------------------------------------------
            case 'transport':
              // Use transport bytes received if candidate-pair didn't provide it reliably
              bytesReceived = report.values['bytesReceived'] ?? bytesReceived;
              break;
          }
        }

        // -------------------------------------------
        // CALCULATIONS (Rate-based metrics)
        // -------------------------------------------
        double? actualBitrateKbps;
        double? avgEncodeTimePerFrameMs;
        final currentTime = DateTime.now();
        // Calculate the time difference (in seconds) since the last run
        final timeDiffSec =
            currentTime.difference(prevTime!).inMilliseconds / 1000.0;

        // 1. Actual Outgoing Bitrate (kbps)
        if (bytesSent != null && prevBytesSent != null && timeDiffSec > 0) {
          final bytesSentDiff = bytesSent - prevBytesSent!;
          // Formula: (Bytes Diff * 8 bits/byte) / (Time Diff in seconds) / 1024 to convert to kbps
          actualBitrateKbps = (bytesSentDiff * 8) / timeDiffSec / 1024;
        }

        // 2. Average Encode Time per Frame (ms/frame)
        if (encodeTimeTotal != null &&
            prevTotalEncodeTime != null &&
            framesEncoded != null &&
            prevFramesEncoded != null) {
          final encodeTimeDiff = encodeTimeTotal - prevTotalEncodeTime!;
          final framesEncodedDiff = framesEncoded - prevFramesEncoded!;

          if (framesEncodedDiff > 0) {
            // Formula: (Time Diff in seconds / Frames Encoded Diff) * 1000 ms/sec
            avgEncodeTimePerFrameMs =
                (encodeTimeDiff / framesEncodedDiff) * 1000;
          }
        }

        // Update persistent values for the next calculation
        prevBytesSent = bytesSent;
        prevTotalEncodeTime = encodeTimeTotal;
        prevFramesEncoded = framesEncoded;
        prevTime = currentTime;

        // -------------------------------------------
        // LOG RESULT (Formatted Output)
        // -------------------------------------------
        logger.debug(
          '[Metrics|STREAM] '
          'FPS=${fps ?? "?"} '
          'res=${width ?? "?"}x${height ?? "?"} '
          'frames(S/E)=${framesSent ?? "?"}/${framesEncoded ?? "?"} '
          'encT(total)=${encodeTimeTotal != null ? (encodeTimeTotal * 1000).toStringAsFixed(1) : "?"}ms '
          'encT(avg)=${avgEncodeTimePerFrameMs != null ? avgEncodeTimePerFrameMs.toStringAsFixed(1) : "?"}ms/frame '
          'key=$keyFrames '
          '↑pkts=$packetsSent '
          '↑bytes=$bytesSent ↓bytes=$bytesReceived '
          'targetBitrate=${targetBitrate != null ? (targetBitrate / 1000).toStringAsFixed(0) : "?"}k '
          'ACTUAL_BITRATE=${actualBitrateKbps != null ? actualBitrateKbps.toStringAsFixed(0) : "?"}kbps '
          'nack=$nack pli=$pli fir=$fir '
          'RTT=${rtt != null ? (rtt * 1000).toStringAsFixed(1) : "?"}ms '
          'ICE=$iceState writable=$writable nominated=$nominated',
        );
      } catch (e, st) {
        logger.error('[Metrics] Failed to get stats', e, st);
      }
    });
  }

  void close(String reason) {
    logger.warn('[ScreenStreamer] Closing: $reason');

    if (AppConfig.instance.webrtcEnableMetrics) {
      /// Stop metrics
      _statsTimer?.cancel();
      _statsTimer = null;
    }

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
