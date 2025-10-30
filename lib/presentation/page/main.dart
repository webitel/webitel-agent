import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

import '../../gen/assets.gen.dart';
import '../../service/video/recorder_lifecycle.dart';
import '../theme/text_style.dart';
import '../../../main.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  WebitelSocket? _socket;

  late final AppLifecycleListener _listener;

  @override
  void initState() {
    _listener = AppLifecycleListener(
      onDetach: _handleAppExit,
      onPause: _handleAppExit,
      onResume: () => _connectSocket(),
      onRestart: () => _connectSocket(),
    );
    super.initState();
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  Future<void> _handleAppExit() async {
    logger.info(
      '[MainPage] App paused/detached — stopping recorders and socket...',
    );
    try {
      await stopAllRecorders();
      await _socket?.disconnect();
    } catch (e, st) {
      logger.error('[MainPage] Error during app exit cleanup: $e', st);
    }
  }

  Future<void> _connectSocket() async {
    try {
      await _socket?.connect();
      await _socket?.authenticate();
      logger.info('[MainPage] Socket connected and authenticated');
    } catch (e) {
      logger.error('[MainPage] Socket connect/auth error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-0.47, -1.0),
            end: Alignment(1.0, 1.0),
            colors: [Color(0xFFD93DF5), Color(0xFF1A2EB2)],
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Container(
                width: 380,
                height: 260,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 32,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SvgPicture.asset(
                      Assets.icons.webitelDeskTrackSuccessfully,
                      width: 72,
                      height: 72,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'You have been successfully logged in',
                      style: AppTextStyles.captureTitle.copyWith(
                        color: Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'You can now continue your work in Workspace',
                      style: AppTextStyles.captureSubtitle.copyWith(
                        color: Colors.black54,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            // Positioned(
            //   bottom: 16,
            //   left: 0,
            //   right: 0,
            //   child: Center(
            //     child: Text(
            //       'v${AppVersions.fullVersion}',
            //       style: TextStyle(
            //         color: Colors.white.withOpacity(0.7),
            //         fontSize: 12,
            //         fontWeight: FontWeight.w400,
            //       ),
            //     ),
            //   ),
            // ),
          ],
        ),
      ),
    );
  }
}
