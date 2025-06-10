// tray.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:tray_manager/tray_manager.dart';
import 'package:webitel_agent_flutter/config.dart'; // Import your AppConfig to get loginUrl
import 'package:webitel_agent_flutter/storage.dart';

class TrayService with TrayListener {
  static final TrayService instance = TrayService._();

  TrayService._();

  final _secureStorage = SecureStorageService();
  String _status = 'offline';
  DateTime? _statusChangedAt;
  Timer? _tooltipTimer;

  void Function()?
  onLogin; // Callback for when login is initiated (to show WebView)

  String? _baseUrl;

  // Method to set the base URL after a successful login
  void setBaseUrl(String url) {
    _baseUrl = url;
    debugPrint('TrayService: Base URL set to $_baseUrl');
    _buildMenu(); // Rebuild menu when base URL/login state might change
  }

  Future<void> initTray() async {
    trayManager.addListener(this);

    await trayManager.setIcon(_iconPathForStatus(_status));
    await trayManager.setToolTip('Status: $_status');

    // --- NEW LOGIC HERE ---
    await _checkInitialLoginStatusAndSetBaseUrl();
    // --- END NEW LOGIC ---

    await _buildMenu(); // Build menu after status and baseUrl are potentially set
  }

  // NEW: Method to check login status on app start and set baseUrl
  Future<void> _checkInitialLoginStatusAndSetBaseUrl() async {
    final token = await _secureStorage.readAccessToken();

    if (token != null) {
      debugPrint('TrayService: Found existing token on launch.');
      // If a token exists, derive the base URL from your AppConfig.loginUrl
      // This assumes AppConfig.loginUrl is consistent and available.
      final Uri loginUri = Uri.parse(
        AppConfig.loginUrl,
      ); // Use your AppConfig.loginUrl
      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      debugPrint(
        'TrayService: Derived Base URL from existing token: $determinedBaseUrl',
      );
      _baseUrl = determinedBaseUrl; // Directly set _baseUrl

      // Set status to online or appropriate logged-in status
      _setStatus('online'); // Or whatever is appropriate for logged-in
    } else {
      debugPrint(
        'TrayService: No existing token found on launch. Starting offline.',
      );
      _setStatus('offline');
    }
  }

  Future<void> _buildMenu() async {
    final token =
        await _secureStorage.readAccessToken(); // Check token for menu state

    Menu menu = Menu(
      items: [
        MenuItem(key: 'status', label: 'Status: $_status', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'online', label: 'Go Online'),
        MenuItem(key: 'pause', label: 'Pause'),
        MenuItem(key: 'break', label: 'Break'),
        MenuItem(key: 'offline', label: 'Go Offline'),
        MenuItem.separator(),
        MenuItem(key: 'login', label: 'Login', disabled: token != null),
        // Disable if logged in
        MenuItem(key: 'logout', label: 'Logout', disabled: token == null),
        // Enable if logged in
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit'),
      ],
    );

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

    _buildMenu(); // Rebuild menu to reflect status change
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
    final token = await _secureStorage.readAccessToken();

    if (token != null) {
      debugPrint('Login menu item clicked, but user is already logged in.');
      // Optional: show a message to the user that they are already logged in.
      return; // Stop here, don't show the WebView
    }

    debugPrint('Login menu item clicked. No token found. Triggering WebView.');
    onLogin?.call(); // This will launch the LoginWebView from main.dart
  }

  Future<void> _performLogoutApiCall(String url, String token) async {
    final api = Uri.parse('$url/api/logout');
    debugPrint('Attempting API logout at: $api');

    try {
      final res = await http.post(
        api,
        headers: {
          "Content-Type": "application/json",
          "x-webitel-access": token,
        },
        body: jsonEncode({}),
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        debugPrint('API logout successful, status: ${res.statusCode}');
      } else {
        debugPrint(
          'API logout failed with status: ${res.statusCode}, body: ${res.body}',
        );
      }
    } catch (e) {
      debugPrint('ERROR: API logout request failed: $e');
    }
  }

  Future<void> _logout() async {
    final token = await _secureStorage.readAccessToken();

    if (token != null && _baseUrl != null) {
      debugPrint('Attempting server logout...');
      await _performLogoutApiCall(_baseUrl!, token);
    } else {
      debugPrint(
        'No token or base URL found for server logout. Performing local logout only.',
      );
    }

    // Always delete the token locally
    await _secureStorage.deleteAccessToken(); // Corrected call with ()
    debugPrint('Logged out. Token deleted locally.');

    _baseUrl = null; // Clear base URL on logout
    _setStatus('offline'); // Set tray status to offline
    _buildMenu(); // Rebuild menu to enable Login and disable Logout
  }
}
