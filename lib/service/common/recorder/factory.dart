import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/service/common/recorder/recorder_interface.dart';
import 'package:webitel_desk_track/service/webrtc/recorder/recorder.dart';

class RecorderFactory {
  final IStorageService _storage;

  RecorderFactory(this._storage);

  RecorderI create({required String id, required String token}) {
    final config = AppConfig.instance;

    return StreamRecorder(
      callId: id,
      token: token,
      sdpResolverUrl: config.webrtcSdpUrl,
      iceServers: config.webrtcIceServers,
      storage: _storage,
    );
  }
}
