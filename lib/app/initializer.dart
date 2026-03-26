import 'package:flutter/material.dart';
import 'package:webitel_desk_track/app/flow.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/presentation/page/main.dart';
import 'package:webitel_desk_track/presentation/page/missing_config.dart';
import 'package:webitel_desk_track/service/ffmpeg/manager/manager.dart';
import 'package:webitel_desk_track/service/tray/tray.dart';
import 'package:window_manager/window_manager.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class AppInitializer {
  static Future<void> run() async {
    logger.info('[AppInitializer] Bootstrap sequence started');

    // 1. Window Configuration
    // [GUARD] Ensure window is initialized before any UI logic
    await windowManager.ensureInitialized();

    // [LOGIC] Set the flag that prevents the app from closing on 'X'
    await windowManager.setPreventClose(true);

    // 2. Load Config & Init Logger
    final config = await AppConfig.load();
    await logger.init(config);

    // 3. System Tray Initialization
    // [LOGIC] Pass storage directly for consistent auth handling
    await TrayService.init(AppFlow.instance.storage);

    if (config != null) {
      // 4. Heavy services setup (FFmpeg)
      FFmpegManager.instance.init();

      runApp(const AppRoot());

      // [LOGIC] Start the main application flow after the first frame is rendered
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await AppFlow.instance.start();
      });
    } else {
      // 5. Fallback if config is missing (fresh install)
      runApp(const MissingConfigRoot());

      TrayService.instance.onConfigUploaded = () async {
        final uploaded = await AppConfig.load();
        if (uploaded != null) {
          await logger.init(uploaded);
          _restartApp();
        } else {
          logger.error(
            '[AppInitializer] Config upload detected but failed to load',
          );
        }
      };
    }
  }

  /// Gracefully shuts down existing instances before re-running flow.
  static Future<void> _restartApp() async {
    logger.warn('[AppInitializer] Restarting application...');

    await AppFlow.instance.shutdown();

    runApp(const AppRoot());

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await AppFlow.instance.start();
    });
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // [LOGIC] Listen to the centralized status provided by AppFlow singleton
    return ValueListenableBuilder<AppStatus>(
      valueListenable: AppFlow.instance.status,
      builder: (context, status, child) {
        switch (status) {
          case AppStatus.ready:
            return const MainPage();
          case AppStatus.authenticating:
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          case AppStatus.failure:
            return const Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, color: Colors.red, size: 48),
                    SizedBox(height: 16),
                    Text("Authentication Failed"),
                  ],
                ),
              ),
            );
          case AppStatus.idle:
          default:
            return const Scaffold(body: SizedBox.shrink());
        }
      },
    );
  }
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const AuthGate(),
    );
  }
}

class MissingConfigRoot extends StatelessWidget {
  const MissingConfigRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MissingConfigPage(),
    );
  }
}
