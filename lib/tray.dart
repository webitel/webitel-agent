import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:flutter/material.dart';

class TrayService with TrayListener {
  static final TrayService instance = TrayService._();
  TrayService._();

  final _secureStorage = const FlutterSecureStorage();
  String _status = 'offline';
  DateTime? _statusChangedAt;
  Timer? _tooltipTimer;

  void Function()? onLogin;

  Future<void> initTray() async {
    trayManager.addListener(this);

    await trayManager.setIcon(_iconPathForStatus(_status));
    await trayManager.setToolTip('Status: $_status');
    await _buildMenu();
  }

  Future<void> _buildMenu() async {
    Menu menu = Menu(items: [
      MenuItem(key: 'status', label: 'Status: $_status', disabled: true),
      MenuItem.separator(),
      MenuItem(key: 'online', label: 'Go Online'),
      MenuItem(key: 'pause', label: 'Pause'),
      MenuItem(key: 'break', label: 'Break'),
      MenuItem(key: 'offline', label: 'Go Offline'),
      MenuItem.separator(),
      MenuItem(key: 'login', label: 'Login'),
      MenuItem(key: 'logout', label: 'Logout'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: 'Exit'),
    ]);

    await trayManager.setContextMenu(menu);
  }

  @override
  void onTrayIconRightMouseUp() => _startTooltipTimer();
  @override
  void onTrayIconRightMouseDown() => _stopTooltipTimer();


  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'online':
      case 'pause':
      case 'break':
      case 'offline':
        _setStatus(menuItem.key!);
        break;
      case 'login':
        _login();
        break;
      case 'logout':
        _logout();
        break;
      case 'exit':
        exit(0);
    }
  }

  void _setStatus(String status) async {
    _status = status;
    _statusChangedAt = DateTime.now();

    await trayManager.setToolTip('Status: $_status');
    await trayManager.setIcon(_iconPathForStatus(status));

    _buildMenu();
  }

  String _iconPathForStatus(String status) {
    switch (status) {
      case 'online':
        return 'assets/green.svg';
      case 'pause':
      case 'break':
        return 'assets/warn.svg';
      default:
        return 'assets/red.svg';
    }
  }

  void _startTooltipTimer() {
    _tooltipTimer?.cancel();
    _tooltipTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_statusChangedAt != null) {
        final elapsed = DateTime.now().difference(_statusChangedAt!);
        final formatted = _formatDuration(elapsed);
        trayManager.setToolTip('$_status • $formatted');
      }
    });
  }

  void _stopTooltipTimer() {
    _tooltipTimer?.cancel();
    _tooltipTimer = null;
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  Future<void> _login() async {
    debugPrint('Login menu item clicked. Triggering WebView.');
    // Call the callback that was set in main.dart
    // This will push the LoginWebView onto the navigation stack.
    onLogin?.call();
  }

  Future<void> _logout() async {
    await _secureStorage.delete(key: 'token');
    debugPrint('Logged out. Token deleted.');
  }
}
