import 'package:flutter/material.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/service/tray/tray.dart';
import 'package:window_manager/window_manager.dart';

import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/presentation/page/main.dart';
import 'package:webitel_desk_track/presentation/page/missing_config.dart';
import 'package:webitel_desk_track/service/ffmpeg/manager/manager.dart';
import 'package:webitel_desk_track/app/flow.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class AppInitializer {
  /// Main bootstrap sequence to prepare the environment and launch the UI
  static Future<void> run() async {
    logger.info('[AppInitializer] Bootstrap sequence started');

    // 1. Desktop window configuration
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);

    // 2. Load application configuration
    final config = await AppConfig.load();
    await logger.init(config);

    // 3. Initialize System Tray with the shared storage from AppFlow
    // We use the storage instance from AppFlow to maintain consistency
    await TrayService.init(AppFlow.instance.storage);

    if (config != null) {
      logger.info('[AppInitializer] Valid config found, launching AppRoot');

      // Initialize media processing tools
      FFmpegManager.instance.init();

      runApp(const AppRoot());

      // Start background services after the first frame is rendered
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await AppFlow.instance.start();
      });
    } else {
      logger.warn('[AppInitializer] Config missing, launching placeholder UI');
      runApp(const MissingConfigRoot());

      // Set up a listener for manual configuration uploads via Tray
      TrayService.instance.onConfigUploaded = () async {
        final uploaded = await AppConfig.load();
        if (uploaded != null) {
          await logger.init(uploaded);
          _restartApp();
        }
      };
    }
  }

  /// Re-triggers the application flow after a configuration update
  static Future<void> _restartApp() async {
    logger.info('[AppInitializer] Restarting application via config update');

    // Gracefully stop all existing services
    await AppFlow.instance.shutdown();

    runApp(const AppRoot());

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await AppFlow.instance.start();
    });
  }
}

/// A gateway widget that switches UI based on the authentication status
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppStatus>(
      valueListenable: AppFlow.instance.status,
      builder: (context, status, child) {
        logger.debug('[AuthGate] Status update: $status');

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

/// Standard root widget for the main application flow
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

/// Root widget used when the application lacks a valid configuration file
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
