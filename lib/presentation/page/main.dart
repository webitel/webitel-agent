import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:webitel_desk_track/app/flow.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/ws/webitel_socket.dart';

import '../../gen/assets.gen.dart';
import '../theme/text_style.dart';

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
    super.initState();
    // Initialize lifecycle listener to handle app exits and backgrounding
    _listener = AppLifecycleListener(
      onExitRequested: () => _handleAppExit(),
      onDetach: _handleAppExit,
      onPause: _handleAppExit,
      onResume: () => _connectSocket(),
      onRestart: () => _connectSocket(),
    );
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  /// Handles graceful cleanup when the user tries to close the application
  Future<AppExitResponse> _handleAppExit() async {
    logger.info('[MainPage] App exit requested — performing cleanup...');

    try {
      // FIX: Accessing shutdown via the singleton instance
      await AppFlow.instance.shutdown();

      await _socket?.disconnect();
      logger.info('[MainPage] Cleanup complete, allowing exit');

      return AppExitResponse.exit;
    } catch (e, st) {
      logger.error('[MainPage] Error during app exit cleanup:', e, st);
      return AppExitResponse.exit;
    }
  }

  /// Restores socket connection when the app returns to the foreground
  Future<void> _connectSocket() async {
    try {
      await _socket?.connect();
      await _socket?.authenticate();
      await _socket?.ready;
      logger.info('[MainPage] Socket connection restored');
    } catch (e, st) {
      logger.error('[MainPage] Socket reconnection error:', e, st);
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
          ],
        ),
      ),
    );
  }
}
