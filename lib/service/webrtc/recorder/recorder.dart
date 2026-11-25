import 'dart:async';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/capturer.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/peer_connection.dart';
import 'package:webitel_desk_track/service/webrtc/common/webrtc/signaling.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';

class StreamRecorder implements RecorderI {
  final String callId;
  final String token;
  final String sdpResolverUrl;
  final List<Map<String, dynamic>> iceServers;
  final IStorageService _storage;

  RTCPeerConnection? pc;
  List<MediaStream> streams = [];
  String? _sessionID;
  bool _isStopping = false;
  Timer? _maxDurationTimer;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;

  @override
  void Function(String reason)? onUnexpectedStop;

  StreamRecorder({
    required this.callId,
    required this.token,
    required this.sdpResolverUrl,
    required this.iceServers,
    required IStorageService storage,
  }) : _storage = storage;

  @override
  Future<void> start({required String recordingId}) {
    // stop() waits for this future, so a stop during start always sees and
    // releases whatever start has opened (capture, peer connection, server stream).
    return _startFuture = _start(recordingId);
  }

  Future<void> _start(String recordingId) async {
    await _cleanupInternal();
    _isStopping = false;

    final logId = recordingId.isNotEmpty ? recordingId : callId;
    logger.info('[StreamRecorder] Initializing WebRTC for $logId');

    _maxDurationTimer = Timer(const Duration(hours: 1), () {
      logger.warn('[StreamRecorder] SAFETY_TIMEOUT reached. Force stopping.');
      _stopUnexpectedly('safety_timeout');
    });

    try {
      pc = await createPeerConnectionWithConfig(iceServers);
      final currentPc = pc!;

      currentPc.onIceGatheringState = (RTCIceGatheringState state) {
        logger.debug('[StreamRecorder] ICE Gathering: ${state.name}');
      };

      currentPc.onIceConnectionState = (RTCIceConnectionState state) {
        logger.debug('[StreamRecorder] ICE Connection State: ${state.name}');

        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          // [CRITICAL] Connection failed permanently. Kill the session.
          logger.error(
            '[StreamRecorder] ICE Failed. Permanent transport loss.',
          );
          _stopUnexpectedly('ice_failed');
        }

        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          // [WARN] Transient disconnect. Let's wait a bit before giving up.
          logger.warn(
            '[StreamRecorder] ICE Disconnected. Waiting for recovery...',
          );

          Future.delayed(const Duration(seconds: 10), () {
            if (!identical(pc, currentPc)) return;
            if (currentPc.iceConnectionState ==
                    RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                currentPc.iceConnectionState ==
                    RTCIceConnectionState.RTCIceConnectionStateFailed) {
              logger.warn(
                '[StreamRecorder] ICE recovery timeout. Closing session.',
              );
              _stopUnexpectedly('ice_disconnected');
            }
          });
        }
      };

      if (Platform.isWindows) {
        streams = await captureAllDesktopScreensWindows(currentPc);
      } else {
        final stream = await captureDesktopScreen();
        if (stream != null) streams = [stream];
      }

      if (_isStopping || streams.isEmpty) throw Exception('No sources found');

      for (final stream in streams) {
        for (final track in stream.getTracks()) {
          logger.debug(
            '[StreamRecorder] Adding track: kind=${track.kind} id=${track.id} enabled=${track.enabled}',
          );
          final sender = await currentPc.addTrack(track, stream);
          if (track.kind == 'video') await _configureVideoEncoding(sender);
        }
      }

      logger.debug(
        '[StreamRecorder] Streams: ${streams.length}, total tracks: ${streams.fold(0, (n, s) => n + s.getTracks().length)}',
      );

      final offer = await currentPc.createOffer();
      if (_isStopping) return;
      await currentPc.setLocalDescription(offer);

      int waitCount = 0;
      while (currentPc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          waitCount < 20) {
        if (_isStopping) return;
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
      }

      final localDesc = await currentPc.getLocalDescription();
      if (localDesc == null) throw Exception('SDP generation failed');

      _logSdpAudioLines(localDesc.sdp ?? '', 'offer');

      final response = await sendSDPToServer(
        url: sdpResolverUrl,
        token: token,
        offer: localDesc,
        id: logId,
        storage: _storage,
      );

      // Keep the id even when stopping: cleanup must DELETE the server stream.
      _sessionID = response.streamId;
      if (_isStopping) return;
      await currentPc.setRemoteDescription(response.answer);

      logger.info('[StreamRecorder] Established Session: $_sessionID');
    } catch (e, st) {
      if (!_isStopping) {
        logger.error('[StreamRecorder] Start failed', e, st);
        await _cleanupInternal();
        rethrow;
      }
    }
  }

  Future<void> _configureVideoEncoding(RTCRtpSender sender) async {
    final params = sender.parameters;
    if (params.encodings!.isEmpty) params.encodings!.add(RTCRtpEncoding());

    params.encodings![0]
      ..maxBitrate = 2500000
      ..minBitrate = 500000
      ..maxFramerate = 15;

    params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
    await sender.setParameters(params);
  }

  @override
  Future<void> stop() => _stopFuture ??= _stop();

  Future<void> _stop() async {
    _isStopping = true;
    _maxDurationTimer?.cancel();
    logger.info('[StreamRecorder] Terminating session for $callId');
    try {
      await _startFuture;
    } catch (_) {}
    await _logVideoStats();
    await _cleanupInternal();
  }

  void _stopUnexpectedly(String reason) {
    if (_isStopping) return;
    logger.warn('[StreamRecorder] Stopped on its own: $reason');
    stop().whenComplete(() => onUnexpectedStop?.call(reason));
  }

  Future<void> _logVideoStats() async {
    final currentPc = pc;
    if (currentPc == null) return;
    try {
      final stats = await currentPc.getStats();
      for (final report in stats) {
        if (report.type == 'outbound-rtp') {
          final v = report.values;
          final kind = v['kind'] ?? v['mediaType'];
          if (kind != 'video') continue;
          final rtpTs = v['rtpTimestamp'] ?? v['timestamp'];
          final frames = v['framesSent'];
          final packets = v['packetsSent'];
          logger.debug(
            '[StreamRecorder] VideoStats: rtpTimestamp=$rtpTs framesSent=$frames packetsSent=$packets',
          );
          // rtpTimestamp/90000 = RTP duration in seconds — compare to actual session duration
          if (rtpTs != null) {
            final rtpSec = (rtpTs as num) / 90000.0;
            logger.debug(
              '[StreamRecorder] VideoStats: RTP duration=${rtpSec.toStringAsFixed(2)}s',
            );
          }
        }
      }
    } catch (e) {
      logger.warn('[StreamRecorder] getStats failed: $e');
    }
  }

  Future<void> _cleanupInternal() async {
    _maxDurationTimer?.cancel();

    final sessionId = _sessionID;
    _sessionID = null;
    if (sessionId != null) {
      try {
        await stopStreamOnServer(
          url: '$sdpResolverUrl/$sessionId',
          token: token,
          id: sessionId,
        ).timeout(const Duration(seconds: 5));
      } catch (e) {
        logger.warn('[StreamRecorder] Server stream $sessionId not closed: $e');
      }
    }

    final ownedStreams = streams;
    streams = [];
    for (final stream in ownedStreams) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }

    final ownedPc = pc;
    pc = null;
    if (ownedPc != null) {
      await ownedPc.close();
      await ownedPc.dispose();
    }
  }

  void _logSdpAudioLines(String sdp, String label) {
    final lines = sdp.split('\n').where((l) {
      if (l.startsWith('m=audio')) return true;
      if (l.startsWith('a=rtpmap')) return true;
      if (l.startsWith('a=fmtp')) return true;
      return false;
    });
    for (final l in lines) {
      logger.debug('[StreamRecorder] SDP $label: ${l.trim()}');
    }
  }

  @override
  Future<void> upload() async {}
  @override
  Future<void> cleanup() async => await _cleanupInternal();
}
