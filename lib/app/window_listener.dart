import 'dart:io';
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
    await windowManager.setPreventClose(true);

    logger.info(
      '[WindowListener] Close button clicked - hiding to tray instead of closing',
    );

    try {
      //FIXME
      //due to this https://github.com/leanflutter/tray_manager/issues/44
      if (Platform.isMacOS) {
        await windowManager.minimize();
      } else {
        await windowManager.hide();
      }

      await windowManager.setSkipTaskbar(true);

      logger.info('[WindowListener] Window hidden. App continues in tray.');
    } catch (e, st) {
      logger.error('[WindowListener] Failed to hide window', e, st);
    }
  }

  static Future<void> exitApp() async {
    final storage = SecureStorageService();
    logger.info('[WindowListener] Exit requested - running full cleanup.');

    // Dispose tray
    try {
      TrayService.instance.dispose();
      logger.info('[WindowListener] Tray disposed.');
    } catch (e, st) {
      logger.warn('[WindowListener] Tray dispose error: $e\n$st');
    }

    try {
      final logoutType = AppConfig.instance.userLogoutType.toLogoutType;

      if (logoutType == UserLogoutType.onClose) {
        logger.info('[WindowListener] Logging out on app exit...');
        final logoutService = LogoutService();
        await logoutService.logout();
        await storage.flush();
      }
    } catch (e, st) {
      logger.error('[WindowListener] Logout on exit error:', e, st);
    }

    try {
      await AppFlow.shutdown();
    } catch (e, st) {
      logger.warn('[WindowListener] AppFlow.shutdown error: $e\n$st');
    }

    try {
      await windowManager.destroy();
      logger.info('[WindowListener] Window destroyed. Exiting...');
    } catch (e, st) {
      logger.error('[WindowListener] Failed to destroy window', e, st);
    }

    exit(0);
  }
}
