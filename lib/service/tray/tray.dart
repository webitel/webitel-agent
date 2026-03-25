import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:webitel_desk_track/app/flow.dart';
import 'package:webitel_desk_track/config/service.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/gen/assets.gen.dart';
import 'package:webitel_desk_track/service/auth/logout.dart';
import 'package:webitel_desk_track/ws/webitel_socket.dart';
import '../../core/logger/logger.dart';

class TrayService with TrayListener {
  // Singleton instance
  static TrayService? _instance;

  // Private constructor with required storage
  TrayService._(this._storage);

  /// Global access to the singleton.
  /// Must call init() before accessing instance.
  static TrayService get instance {
    if (_instance == null) {
      throw Exception(
        'TrayService must be initialized with init(storage) first.',
      );
    }
    return _instance!;
  }

  /// Entry point for tray initialization. Sets the singleton instance.
  static Future<void> init(IStorageService storage) async {
    if (_instance != null) return; // Prevent double initialization
    _instance = TrayService._(storage);
    await _instance!._setupTray();
  }

  final IStorageService _storage;
  String _status = 'offline';
  DateTime? _statusChangedAt;
  Timer? _tooltipTimer;

  void Function()? onLogin;
  String? _baseUrl;
  WebitelSocket? _socket;
  StreamSubscription<String>? _agentStatusSubscription;
  Future<void> Function()? onConfigUploaded;

  /// Internal logic to prepare the tray UI
  Future<void> _setupTray() async {
    trayManager.addListener(this);
    await trayManager.setIcon(_iconPathForStatus(_status));
    await trayManager.setToolTip('Status: $_status');
    await _checkInitialLoginStatusAndSetBaseUrl();
    await _buildMenu();
    logger.info('[TrayService] Initialized and UI built.');
  }

  void updateStatus(String status) => _setStatus(status);

  /// Links the tray to the socket stream for real-time status updates
  void attachSocket(WebitelSocket socket) {
    _socket = socket;
    _agentStatusSubscription?.cancel();
    _agentStatusSubscription = _socket!.agentStatusStream.listen((status) {
      logger.info('[TrayService] Agent status update: $status');
      _setStatus(status);
    });
  }

  void setBaseUrl(String url) {
    _baseUrl = url;
    _buildMenu();
  }

  /// Checks if we have a token to determine if we are online or offline at start
  Future<void> _checkInitialLoginStatusAndSetBaseUrl() async {
    final token = await _storage.readAccessToken();
    if (token != null && token.isNotEmpty) {
      final loginUrl =
          (() {
            try {
              final url = AppConfig.instance.loginUrl;
              if (url.isNotEmpty) return url;
            } catch (_) {}
            return AppConfig.instance.baseUrl;
          })();

      final Uri loginUri = Uri.parse(loginUrl);
      _baseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';
    } else {
      logger.warn('[TrayService] Starting in offline mode (no token).');
    }
  }

  /// Context menu items and structure
  Future<void> _buildMenu() async {
    final items = <MenuItem>[
      MenuItem(key: 'status', label: 'Status: $_status', disabled: true),
      MenuItem.separator(),
      MenuItem(key: 'upload_config', label: 'Upload Configuration'),
      MenuItem.separator(),
      MenuItem(key: 'logout', label: 'Logout'),
      MenuItem.separator(),
      MenuItem(key: 'close', label: 'Close'),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'upload_config':
        _handleUploadConfig();
        break;
      case 'logout':
        _handleLogout();
        break;
      case 'close':
        exit(0);
        break;
    }
  }

  Future<void> _handleLogout() async {
    await LogoutService(storage: _storage).logout();
    await trayManager.setToolTip('Logged out');
    await AppFlow.instance.interactiveRelogin();
  }

  /// Opens file picker to manually update app configuration via JSON
  Future<void> _handleUploadConfig() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (file != null) {
        final content = await File(file.path).readAsString();
        await AppConfig.save(jsonDecode(content));
        await AppConfig.load();
        if (onConfigUploaded != null) await onConfigUploaded!();
      }
    } catch (e, s) {
      logger.error('[TrayService] Config upload failed:', e, s);
    }
  }

  void _setStatus(String status) async {
    _status = status;
    _statusChangedAt = DateTime.now();
    await trayManager.setToolTip('Status: $_status');
    await trayManager.setIcon(_iconPathForStatus(status));
    await _buildMenu();
  }

  /// Returns the correct asset path based on agent status and OS
  String _iconPathForStatus(String status) {
    final isWindows = Platform.isWindows;
    final s = status.toLowerCase();
    if (s == 'online')
      return isWindows ? Assets.icons.online : Assets.icons.wtCaptureOnline;
    if (s == 'pause' || s == 'break')
      return isWindows ? Assets.icons.pause : Assets.icons.wtCapturePause;
    return isWindows ? Assets.icons.offline : Assets.icons.wtCaptureOffline;
  }

  void _startTooltipTimer() {
    _tooltipTimer?.cancel();
    _tooltipTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_statusChangedAt != null) {
        final elapsed = DateTime.now().difference(_statusChangedAt!);
        await trayManager.setToolTip('$_status • ${_formatDuration(elapsed)}');
      }
    });
  }

  String _formatDuration(Duration d) {
    String f(int n) => n.toString().padLeft(2, '0');
    return "${f(d.inHours)}:${f(d.inMinutes.remainder(60))}:${f(d.inSeconds.remainder(60))}";
  }

  @override
  void onTrayIconRightMouseUp() => _startTooltipTimer();
  @override
  void onTrayIconRightMouseDown() => _tooltipTimer?.cancel();
  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  void dispose() {
    _agentStatusSubscription?.cancel();
    _tooltipTimer?.cancel();
    trayManager.removeListener(this);
  }
}
