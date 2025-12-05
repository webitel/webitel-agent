import 'dart:async'; // Required for Timer
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/service/common/webrtc/capturer.dart';
import 'package:webitel_desk_track/service/common/webrtc/peer_connection.dart';
import 'package:webitel_desk_track/service/common/webrtc/signaling.dart';
import 'package:webitel_desk_track/service/recording/recorder.dart';

class StreamRecorder implements Recorder {
  final String callId;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;

  RTCPeerConnection? pc;
  List<MediaStream> streams = [];
  String? _sessionID;

  // --- METRICS STATE ---
  Timer? _statsTimer;
  // Persistent state for calculating rates (Kbps, Avg Encode Time)
  int? _prevBytesSent = 0;
  double? _prevTotalEncodeTime = 0.0;
  int? _prevFramesEncoded = 0;
  DateTime? _prevTime = DateTime.now();
  // ---------------------

  StreamRecorder({
    required this.callId,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
  });

  @override
  Future<void> start({required String recordingId}) async {
    logger.info('[StreamRecorder] Starting stream for $callId');
    pc = await createPeerConnectionWithConfig(iceServers);

    pc!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        logger.warn('[StreamRecorder] ICE failed, stopping...');
        // Stopping also cancels the metrics timer
        stop();
      }
    };

    pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        // Start metrics monitoring once the connection is established
        if (AppConfig.instance.webrtcEnableMetrics) {
          _startMetricsMonitor();
          logger.info('[StreamRecorder] WebRTC Metrics Monitor started.');
        }
      }
    };

    // Capture screen based on platform
    if (Platform.isWindows) {
      streams = await captureAllDesktopScreensWindows(
        FFmpegMode.recording,
        pc!,
      );
    } else {
      final stream = await captureDesktopScreen();
      if (stream != null) streams = [stream];
    }

    if (streams.isEmpty) throw Exception('No screens captured');

    // Add tracks to the PeerConnection
    for (final s in streams) {
      for (final t in s.getTracks()) {
        final sender = await pc!.addTrack(t, s);

        if (t.kind == 'video') {
          // Configure video encoding parameters
          final params = sender.parameters;
          if (params.encodings!.isEmpty) {
            params.encodings!.add(RTCRtpEncoding());
          }
          params.encodings![0].maxBitrate = 4_000_000;
          params.encodings![0].minBitrate = 500_000;
          params.encodings![0].maxFramerate = AppConfig.instance.framerate;
          params.encodings![0].scaleResolutionDownBy = 1.0;
          params.degradationPreference =
              RTCDegradationPreference.MAINTAIN_RESOLUTION;
          await sender.setParameters(params);
        }
      }
    }

    // SDP Offer/Answer process
    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);

    final desc = await pc!.getLocalDescription();
    if (desc == null) throw Exception('Local SDP is null');

    final response = await sendSDPToServer(
      url: sdpResolverUrl,
      token: token,
      offer: desc,
      id: callId,
    );

    _sessionID = response.streamId;
    await pc!.setRemoteDescription(response.answer);
    logger.info('[StreamRecorder] Stream started (id=$_sessionID)');
  }

  /// WebRTC METRICS MONITOR: Collects and logs performance statistics every second.
  void _startMetricsMonitor() {
    _statsTimer?.cancel();

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final currentPC = pc;
      if (currentPC == null) return;

      // Temporary local variables for stats
      double? fps;
      int? width;
      int? height;
      int? framesSent;
      int? framesEncoded;
      double? encodeTimeTotal;
      int? keyFrames;
      int? bytesSent;
      int? nack;
      int? pli;
      int? fir;
      int? targetBitrate;
      double? rtt;
      int? bytesReceived;
      bool? writable;
      bool? nominated;
      String? iceState;

      try {
        final reports = await currentPC.getStats();
        final currentTime = DateTime.now();
        // Time difference for rate calculations (Kbps, ms/frame)
        final timeDiffSec =
            currentTime.difference(_prevTime!).inMilliseconds / 1000.0;

        for (final report in reports) {
          switch (report.type) {
            // MEDIA SOURCE — FPS + RESOLUTION
            case 'media-source':
              if (report.values['kind'] == 'video') {
                fps = (report.values['framesPerSecond'] as num?)?.toDouble();
                width = report.values['width'];
                height = report.values['height'];
              }
              break;
            // TRACK
            case 'track':
              if (report.values['kind'] == 'video') {
                fps =
                    (report.values['framesSentPerSecond'] as num?)
                        ?.toDouble() ??
                    fps;
              }
              break;
            // OUTBOUND RTP (Encoding and Sending Stats)
            case 'outbound-rtp':
              if (report.values['kind'] == 'video') {
                framesSent = report.values['framesSent'];
                framesEncoded = report.values['framesEncoded'];
                encodeTimeTotal =
                    (report.values['totalEncodeTime'] as num?)?.toDouble();
                keyFrames = report.values['keyFramesEncoded'];
                bytesSent = report.values['bytesSent'];
                nack = report.values['nackCount'];
                pli = report.values['pliCount'];
                fir = report.values['firCount'];
                targetBitrate =
                    (report.values['targetBitrate'] as num?)?.toInt();
              }
              break;
            // CANDIDATE PAIR — RTT + network health
            case 'candidate-pair':
              if (report.values['state'] == 'succeeded' &&
                  (report.values['nominated'] == true || rtt == null)) {
                rtt =
                    (report.values['currentRoundTripTime'] as num?)?.toDouble();
                bytesReceived = report.values['bytesReceived'];
                writable = report.values['writable'];
                nominated = report.values['nominated'];
                iceState = report.values['state'];
              }
              break;
            // TRANSPORT (Fallback for reliable bytesReceived)
            case 'transport':
              bytesReceived = report.values['bytesReceived'] ?? bytesReceived;
              break;
          }
        }

        // --- RATE CALCULATIONS ---
        double? actualBitrateKbps;
        double? avgEncodeTimePerFrameMs;

        // 1. Actual Outgoing Bitrate (kbps)
        if (bytesSent != null && _prevBytesSent != null && timeDiffSec > 0) {
          final bytesSentDiff = bytesSent - _prevBytesSent!;
          // (Bytes Diff * 8 bits/byte) / (Time Diff in seconds) / 1024 to convert to kbps
          actualBitrateKbps = (bytesSentDiff * 8) / timeDiffSec / 1024;
        }

        // 2. Average Encode Time per Frame (ms/frame)
        if (encodeTimeTotal != null &&
            _prevTotalEncodeTime != null &&
            framesEncoded != null &&
            _prevFramesEncoded != null) {
          final encodeTimeDiff = encodeTimeTotal - _prevTotalEncodeTime!;
          final framesEncodedDiff = framesEncoded - _prevFramesEncoded!;

          if (framesEncodedDiff > 0) {
            // (Time Diff in seconds / Frames Encoded Diff) * 1000 ms/sec
            avgEncodeTimePerFrameMs =
                (encodeTimeDiff / framesEncodedDiff) * 1000;
          }
        }

        // Update persistent values for the next interval
        _prevBytesSent = bytesSent;
        _prevTotalEncodeTime = encodeTimeTotal;
        _prevFramesEncoded = framesEncoded;
        _prevTime = currentTime;

        // --- LOG RESULT ---
        // Logging uses the unique '[Metrics]' prefix for custom coloring in the console.
        logger.debug(
          '[Metrics|RECORD] '
          'FPS=${fps ?? "?"} '
          'res=${width ?? "?"}x${height ?? "?"} '
          'frames(S/E)=${framesSent ?? "?"}/${framesEncoded ?? "?"} '
          'encT(avg)=${avgEncodeTimePerFrameMs != null ? avgEncodeTimePerFrameMs.toStringAsFixed(1) : "?"}ms/frame '
          'key=$keyFrames '
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

  @override
  Future<void> stop() async {
    logger.info('[StreamRecorder] Stopping stream...');

    // --- STOP METRICS MONITORING ---
    _statsTimer?.cancel();
    _statsTimer = null;
    // -------------------------------

    await stopStereoAudioFFmpeg(FFmpegMode.recording);

    if (_sessionID != null) {
      try {
        // Send termination request to the server
        await stopStreamOnServer(
          url: '$sdpResolverUrl/$_sessionID',
          token: token,
          id: _sessionID!,
        );
      } catch (e) {
        logger.warn('[StreamRecorder] stopStreamOnServer failed: $e');
      }
    }

    // Stop and clear local media streams/tracks
    for (final s in streams) {
      for (var t in s.getTracks()) {
        t.stop();
      }
    }
    streams.clear();

    // Close and dispose of the PeerConnection
    await pc?.close();
    pc = null;
  }

  @override
  Future<void> upload() async {
    // WebRTC streaming — upload not applicable
  }

  @override
  Future<void> cleanup() async {
    // Nothing to cleanup for live streams
  }
}
