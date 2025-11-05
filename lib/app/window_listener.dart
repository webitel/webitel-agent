// lib/app/window_listener.dart
import 'package:window_manager/window_manager.dart';
import 'package:webitel_agent_flutter/service/system/tray.dart';
import 'package:webitel_agent_flutter/app/flow.dart';
import 'package:webitel_agent_flutter/core/logger.dart';

class MyWindowListener extends WindowListener {
  @override
  Future<void> onWindowClose() async {
    logger.info('[WindowListener] Intercepted window close — running cleanup.');

    // ensure tray disposed
    try {
      TrayService.instance.dispose();
    } catch (e, st) {
      logger.warn('[WindowListener] Tray dispose error: $e\n$st');
    }

    // perform global cleanup via AppFlow
    try {
      await AppFlow.shutdown();
    } catch (e, st) {
      logger.warn('[WindowListener] AppFlow.shutdown error: $e\n$st');
    }

    // finally destroy the window (will close process)
    await windowManager.destroy();
  }
}