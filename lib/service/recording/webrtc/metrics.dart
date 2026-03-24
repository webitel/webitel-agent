import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/core/logger.dart';

/// Service responsible for collecting and logging WebRTC statistics.
class WebRTCMetricsReporter {
  final RTCPeerConnection _pc;
  Timer? _statsTimer;

  // Persistent state for rate calculations
  int? _prevBytesSent = 0;
  double? _prevTotalEncodeTime = 0.0;
  int? _prevFramesEncoded = 0;
  DateTime? _prevTime = DateTime.now();

  WebRTCMetricsReporter(this._pc);

  void start() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _collect());
    logger.info('[Metrics] WebRTC Metrics Reporter started.');
  }

  void stop() {
    _statsTimer?.cancel();
    _statsTimer = null;
    logger.info('[Metrics] WebRTC Metrics Reporter stopped.');
  }

  Future<void> _collect() async {
    try {
      final reports = await _pc.getStats();
      final currentTime = DateTime.now();
      final timeDiffSec =
          currentTime.difference(_prevTime!).inMilliseconds / 1000.0;

      double? fps, avgEncodeTimeMs, actualBitrateKbps;
      int? width,
          height,
          framesSent,
          framesEncoded,
          bytesSent,
          bytesReceived,
          targetBitrate;
      double? rtt;
      String? iceState;

      for (final report in reports) {
        switch (report.type) {
          case 'media-source':
            if (report.values['kind'] == 'video') {
              fps = (report.values['framesPerSecond'] as num?)?.toDouble();
              width = report.values['width'];
              height = report.values['height'];
            }
            break;
          case 'outbound-rtp':
            if (report.values['kind'] == 'video') {
              framesSent = report.values['framesSent'];
              framesEncoded = report.values['framesEncoded'];
              bytesSent = report.values['bytesSent'];
              targetBitrate = (report.values['targetBitrate'] as num?)?.toInt();
              final encodeTime =
                  (report.values['totalEncodeTime'] as num?)?.toDouble();

              // Calculate Bitrate
              if (bytesSent != null &&
                  _prevBytesSent != null &&
                  timeDiffSec > 0) {
                actualBitrateKbps =
                    ((bytesSent - _prevBytesSent!) * 8) / timeDiffSec / 1024;
              }

              // Calculate Avg Encode Time
              if (encodeTime != null &&
                  _prevTotalEncodeTime != null &&
                  framesEncoded != null &&
                  _prevFramesEncoded != null) {
                final fDiff = framesEncoded - _prevFramesEncoded!;
                if (fDiff > 0) {
                  avgEncodeTimeMs =
                      ((encodeTime - _prevTotalEncodeTime!) / fDiff) * 1000;
                }
              }

              _prevBytesSent = bytesSent;
              _prevTotalEncodeTime = encodeTime;
              _prevFramesEncoded = framesEncoded;
            }
            break;
          case 'candidate-pair':
            if (report.values['state'] == 'succeeded') {
              rtt = (report.values['currentRoundTripTime'] as num?)?.toDouble();
              iceState = report.values['state'];
            }
            break;
        }
      }

      _prevTime = currentTime;

      logger.debug(
        '[Metrics|RECORD] FPS=${fps ?? "?"} Res=${width}x$height '
        'Bitrate=${actualBitrateKbps?.toStringAsFixed(0)}kbps '
        'Enc=${avgEncodeTimeMs?.toStringAsFixed(1)}ms/f RTT=${rtt != null ? (rtt * 1000).toInt() : "?"}ms '
        'ICE=$iceState',
      );
    } catch (e) {
      logger.error('[Metrics] Collection error: $e');
    }
  }
}
