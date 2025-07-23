import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:webitel_agent_flutter/gen/assets.gen.dart';
import 'package:webitel_agent_flutter/storage.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

import 'config/config.dart';
import 'logger.dart';

class TrayService with TrayListener {
  static final TrayService instance = TrayService._();

  final _secureStorage = SecureStorageService();

  TrayService._();

  String _status = 'offline';
  DateTime? _statusChangedAt;
  Timer? _tooltipTimer;

  void Function()? onLogin;
  String? _baseUrl;

  WebitelSocket? _socket;
  StreamSubscription<AgentStatus>? _agentStatusSubscription;

  void updateStatus(String status) {
    _setStatus(status);
  }

  void attachSocket(WebitelSocket socket) {
    _socket = socket;
    _agentStatusSubscription?.cancel();
    _agentStatusSubscription = _socket!.agentStatusStream.listen((status) {
      logger.info('TrayService: Received agent status update: $status');
      _setStatus(status.name);
    });
  }

  Future<void> initTray() async {
    trayManager.addListener(this);
    await trayManager.setIcon(_iconPathForStatus(_status));
    await trayManager.setToolTip('Status: $_status');

    await _checkInitialLoginStatusAndSetBaseUrl();
    await _buildMenu();
  }

  void setBaseUrl(String url) {
    _baseUrl = url;
    logger.debug('TrayService: Base URL set to $_baseUrl');
    _buildMenu();
  }

  Future<void> _checkInitialLoginStatusAndSetBaseUrl() async {
    final token = await _secureStorage.readAccessToken();

    if (token != null) {
      logger.debug('TrayService: Found existing token on launch.');
      final loginUrl =
          (() {
            try {
              final url = AppConfig.instance.loginUrl;
              if (url.isNotEmpty) return url;
            } catch (_) {}
            return 'https:dev.webitel.com';
          })();

      final Uri loginUri = Uri.parse(loginUrl);

      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      logger.debug('TrayService: Derived Base URL: $determinedBaseUrl');
      _baseUrl = determinedBaseUrl;
    } else {
      logger.warn('TrayService: No token found. Starting in offline mode.');
    }
  }

  Future<void> _buildMenu() async {
    final menu = Menu(
      items: [
        MenuItem(key: 'status', label: 'Status: $_status', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'upload_config', label: 'Upload Configuration'),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'upload_config') {
      _handleUploadConfig();
    }
  }

  @override
  void onTrayIconRightMouseUp() => _startTooltipTimer();

  @override
  void onTrayIconRightMouseDown() => _stopTooltipTimer();

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  Future<void> Function()? onConfigUploaded;

  Future<void> _handleUploadConfig() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (file != null) {
        final content = await File(file.path).readAsString();
        final json = jsonDecode(content);
        await AppConfig.save(json);
        await AppConfig.load();

        logger.info('TrayService: Config uploaded successfully.');
        await trayManager.setToolTip('✅ Config updated');

        if (onConfigUploaded != null) {
          await onConfigUploaded!();
        }
      }
    } catch (e, s) {
      logger.error('TrayService: Failed to upload config: $e\n$s');
      await trayManager.setToolTip('❌ Config upload failed');
    }
  }

  void _setStatus(String status) async {
    logger.info('Setting status to $status');

    _status = status;
    _statusChangedAt = DateTime.now();

    await trayManager.setToolTip('Status: $_status');
    await trayManager.setIcon(_iconPathForStatus(status));
    await _buildMenu();
  }

  String _iconPathForStatus(String status) {
    switch (status) {
      case 'online':
        return Assets.icons.wtCaptureOnline;
      case 'pause':
        return Assets.icons.wtCapturePause;
      case 'break':
        return Assets.icons.wtCapturePause;
      default:
        return Assets.icons.wtCaptureOffline;
    }
  }

  void _startTooltipTimer() {
    _tooltipTimer?.cancel();
    _tooltipTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_statusChangedAt != null) {
        final elapsed = DateTime.now().difference(_statusChangedAt!);
        final formatted = _formatDuration(elapsed);
        await trayManager.setToolTip('$_status • $formatted');
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

  void dispose() {
    _agentStatusSubscription?.cancel();
    trayManager.removeListener(this);
  }
}
