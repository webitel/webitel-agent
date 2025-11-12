// lib/app/window_listener.dart
import 'package:webitel_desk_track/config/config.dart';
import 'package:webitel_desk_track/config/model/config.dart';
import 'package:webitel_desk_track/service/auth/logout.dart';
import 'package:webitel_desk_track/storage/storage.dart';
import 'package:window_manager/window_manager.dart';
import 'package:webitel_desk_track/service/system/tray.dart';
import 'package:webitel_desk_track/app/flow.dart';
import 'package:webitel_desk_track/core/logger.dart';

class MyWindowListener extends WindowListener {
  @override
  Future<void> onWindowClose() async {
    final storage = SecureStorageService();
    logger.info('[WindowListener] Intercepted window close — running cleanup.');

    // ensure tray disposed
    try {
      TrayService.instance.dispose();
    } catch (e, st) {
      logger.warn('[WindowListener] Tray dispose error: $e\n$st');
    }

    try {
      final logoutType = AppConfig.instance.userLogoutType.toLogoutType;

      if (logoutType == UserLogoutType.onClose) {
        logger.info('Logging out on app close...');

        final logoutService = LogoutService();
        await logoutService.logout();
        await storage.flush();
      }
    } catch (e, st) {
      logger.error('[WindowListener] Logout on close error:', e, st);
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
