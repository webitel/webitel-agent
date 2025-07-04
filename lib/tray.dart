import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tray_manager/tray_manager.dart';
import 'package:webitel_agent_flutter/config.dart';
import 'package:webitel_agent_flutter/storage.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

import 'logger.dart';

class TrayService with TrayListener {
  static final TrayService instance = TrayService._();

  final _logger = LoggerService();
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
      _logger.info('TrayService: Received agent status update: $status');
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
    _logger.debug('TrayService: Base URL set to $_baseUrl');
    _buildMenu();
  }

  Future<void> _checkInitialLoginStatusAndSetBaseUrl() async {
    final token = await _secureStorage.readAccessToken();

    if (token != null) {
      _logger.debug('TrayService: Found existing token on launch.');
      final Uri loginUri = Uri.parse(AppConfig.loginUrl);
      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      _logger.debug('TrayService: Derived Base URL: $determinedBaseUrl');
      _baseUrl = determinedBaseUrl;

      _setStatus('online');
    } else {
      _logger.warn('TrayService: No token found. Starting in offline mode.');
      _setStatus('offline');
    }
  }

  Future<void> _buildMenu() async {
    final token = await _secureStorage.readAccessToken();
    final isAuthorized = token != null && token.isNotEmpty;

    final menu = Menu(
      items: [
        MenuItem(key: 'status', label: 'Status: $_status', disabled: true),
        MenuItem.separator(),

        MenuItem(
          key: 'online',
          label: 'Go Online',
          disabled: !isAuthorized || _status == 'online',
        ),
        MenuItem(
          key: 'pause',
          label: 'Pause',
          disabled: !isAuthorized || _status == 'pause',
        ),
        MenuItem(
          key: 'break',
          label: 'Break',
          disabled: !isAuthorized || _status == 'break',
        ),
        MenuItem(
          key: 'offline',
          label: 'Go Offline',
          disabled: !isAuthorized || _status == 'offline',
        ),

        MenuItem.separator(),

        MenuItem(key: 'login', label: 'Login', disabled: isAuthorized),
        MenuItem(key: 'logout', label: 'Logout', disabled: !isAuthorized),

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
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final agentID = await _secureStorage.readAgentId();
    switch (menuItem.key) {
      case 'online':
        _socket?.setOnline(agentID ?? 0).catchError((e) {
          _logger.error('Failed to go online', e);
        });
        break;
      case 'pause':
        _socket?.setPause(agentId: agentID ?? 0, payload: "Break").catchError((
          e,
        ) {
          _logger.error('Failed to go break', e);
        });
      case 'break':
        _setStatus(menuItem.key!);
        break;
      case 'offline':
        _socket?.setOffline(agentID ?? 0).catchError((e) {
          _logger.error('Failed to go offline', e);
        });
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
    _logger.info('Setting status to $status');

    _status = status;
    _statusChangedAt = DateTime.now();

    await trayManager.setToolTip('Status: $_status');
    await trayManager.setIcon(_iconPathForStatus(status));
    await _buildMenu();
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

  Future<void> _login() async {
    final token = await _secureStorage.readAccessToken();
    if (token != null) {
      _logger.warn('Login triggered, but token already exists.');
      return;
    }

    _logger.info('Triggering login UI via callback.');
    onLogin?.call();
  }

  Future<void> _performLogoutApiCall(String url, String token) async {
    final api = Uri.parse('$url/api/logout');
    _logger.debug('Sending logout request to $api');

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
        _logger.info('Logout API call successful: ${res.statusCode}');
      } else {
        _logger.warn(
          'Logout API call failed: ${res.statusCode}, body: ${res.body}',
        );
      }
    } catch (e, stackTrace) {
      _logger.error('Logout API request failed', e, stackTrace);
    }
  }

  Future<void> _logout() async {
    final token = await _secureStorage.readAccessToken();

    if (token != null && _baseUrl != null) {
      _logger.debug('Performing server logout...');
      await _performLogoutApiCall(_baseUrl!, token);
    } else {
      _logger.warn('No token or base URL. Only performing local logout.');
    }

    await _secureStorage.deleteAccessToken();
    _logger.info('Token deleted locally, user logged out.');

    _baseUrl = null;
    _setStatus('offline');
    await _buildMenu();
  }

  void dispose() {
    _agentStatusSubscription?.cancel();
    trayManager.removeListener(this);
  }
}
