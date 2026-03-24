import 'package:flutter/material.dart';
import 'package:webitel_desk_track/service/ffmpeg_manager/ffmpeg_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/presentation/page/main.dart';
import 'package:webitel_desk_track/presentation/page/missing_config.dart';
import 'package:webitel_desk_track/app/flow.dart';
import 'package:webitel_desk_track/service/system/tray.dart';
import 'package:webitel_desk_track/app/window_listener.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class AppInitializer {
  static Future<void> run() async {
    // --- Window Setup ---
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(MyWindowListener());

    // --- Try to load config ---
    final config = await AppConfig.load();
    await logger.init(config);

    // --- Initialize system tray ---
    await TrayService.instance.initTray();

    if (config != null) {
      FFmpegManager.instance.init();
      // Config exists → start main app
      runApp(const AppRoot());
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await AppFlow.start();
      });
    } else {
      // Config missing → show placeholder app
      runApp(const MissingConfigRoot());

      // When config uploaded via tray → restart cleanly
      TrayService.instance.onConfigUploaded = () async {
        final uploaded = await AppConfig.load();
        if (uploaded != null) {
          await logger.init(uploaded);
          _restartApp();
        } else {
          logger.error('AppInitializer: config upload failed to load');
        }
      };
    }
  }

  /// Clean restart of the app (without Phoenix)
  static Future<void> _restartApp() async {
    logger.warn('[AppInitializer] Restarting application...');
    await AppFlow.shutdown();
    runApp(const AppRoot());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await AppFlow.start();
    });
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppStatus>(
      valueListenable: AppFlow.status,
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
              body: Center(child: Text("Authentication Failed")),
            );
          case AppStatus.idle:
            return const Scaffold(body: SizedBox.shrink());
        }
      },
    );
  }
}

/// Root app when config is valid
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

/// Root app when config is missing
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
