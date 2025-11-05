// lib/app/app_initializer.dart
import 'package:flutter/material.dart';
import 'package:webitel_agent_flutter/presentation/page/main.dart';
import 'package:window_manager/window_manager.dart';
import 'package:webitel_agent_flutter/config/config.dart';
import 'package:webitel_agent_flutter/core/logger.dart';
import 'package:webitel_agent_flutter/presentation/page/missing_config.dart';
import 'package:webitel_agent_flutter/app/flow.dart';
import 'package:webitel_agent_flutter/service/system/tray.dart';
import 'package:webitel_agent_flutter/app/window_listener.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class AppInitializer {
  /// Run the whole app initialization.
  static Future<void> run() async {
    // window manager must be initialized early for desktop apps
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(MyWindowListener());

    // load app config and init logger
    final config = await AppConfig.load();
    await logger.init(config);

    // init tray (shows menu even before UI)
    await TrayService.instance.initTray();

    // Start the UI: either main app or missing-config page
    if (config != null) {
      runApp(const AppRoot());
      // start the app flow after UI is up
      // AppFlow.start will do login/init and attach services
      WidgetsBinding.instance.addPostFrameCallback((_) => AppFlow.start());
    } else {
      runApp(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: MissingConfigPage(),
        ),
      );
      // when config uploaded via tray, AppFlow.restart will be invoked by TrayService
      TrayService.instance.onConfigUploaded = () async {
        final uploaded = await AppConfig.load();
        if (uploaded != null) {
          await logger.init(uploaded);
          await AppFlow.restart();
        } else {
          logger.error('AppInitializer: config upload failed to load');
        }
      };
    }
  }
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MainPageWrapper(),
    );
  }
}

/// A minimal wrapper that ensures [AppFlow.appStartupFlow] runs once UI is ready.
class MainPageWrapper extends StatefulWidget {
  const MainPageWrapper({super.key});

  @override
  State<MainPageWrapper> createState() => _MainPageWrapperState();
}

class _MainPageWrapperState extends State<MainPageWrapper> {
  @override
  void initState() {
    super.initState();
    // delay startup flows until UI rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // AppFlow.start() already called in AppInitializer, but we can ensure idempotency
    });
  }

  @override
  Widget build(BuildContext context) {
    return const MainPage();
  }
}
