import 'dart:io';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';
import 'package:webitel_desk_track/service/ffmpeg/recorder/recorder.dart';
import 'package:webitel_desk_track/service/webrtc/recorder/recorder.dart';

class RecorderFactory {
  final IStorageService _storage;

  RecorderFactory(this._storage);

  RecorderI create({required String id, required String token}) {
    final config = AppConfig.instance;

    // On Windows, FFmpeg muxes audio+video into one container — A/V sync is
    // guaranteed by the muxer. WebRTC DataChannel has no RTP timestamps so
    // the server cannot reliably align audio with video frames.
    if (Platform.isWindows || config.videoSaveLocally) {
      return LocalVideoRecorder(
        callId: id,
        agentToken: token,
        baseUrl: config.baseUrl,
        storage: _storage,
        channel: 'screenrecording',
      );
    }

    return StreamRecorder(
      callId: id,
      token: token,
      sdpResolverUrl: config.webrtcSdpUrl,
      iceServers: config.webrtcIceServers,
      storage: _storage,
    );
  }
}
