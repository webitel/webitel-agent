import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureWidget extends StatefulWidget {
  const ScreenCaptureWidget({super.key});

  @override
  State<ScreenCaptureWidget> createState() => _ScreenCaptureWidgetState();
}

class _ScreenCaptureWidgetState extends State<ScreenCaptureWidget> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  MediaStream? _screenStream;

  @override
  void initState() {
    super.initState();
    _initializeRendererAndStartCapture();
  }

  Future<void> _initializeRendererAndStartCapture() async {
    await _renderer.initialize();

    final constraints = {
      'video': {
        'displaySurface': 'window',
        'mandatory': {'maxWidth': 1920, 'maxHeight': 1080, 'maxFrameRate': 30},
      },
      'audio': false,
    };

    try {
      final stream = await mediaDevices.getDisplayMedia(constraints);
      _renderer.srcObject = stream;

      setState(() {
        _screenStream = stream;
      });
    } catch (e) {
      print('Error capturing screen: $e');
    }
  }

  @override
  void dispose() {
    _screenStream?.getTracks().forEach((t) => t.stop());
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Screen Capture Preview')),
      body: Center(
        child:
            _screenStream == null
                ? const CircularProgressIndicator()
                : RTCVideoView(
                  _renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
      ),
    );
  }
}
