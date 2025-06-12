import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webitel_agent_flutter/presentation/main.dart';
import 'package:webitel_agent_flutter/screenshot.dart';
import 'package:webitel_agent_flutter/ws/config.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

import 'config.dart';
import 'logger.dart';
import 'login.dart';
import 'storage.dart';
import 'tray.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  final logger = LoggerService();

  final storage = SecureStorageService();

  await TrayService.instance.initTray();

  TrayService.instance.onLogin = () async {
    logger.debug('TrayService: Login initiated. Launching WebView...');
    await navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
    );

    logger.debug('LoginWebView has closed. Checking login status...');
    final token = await storage.readAccessToken();

    if (token != null) {
      logger.debug('Login successful. Token found.');

      final Uri loginUri = Uri.parse(AppConfig.loginUrl);
      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      logger.debug('Determined Base URL for API calls: $determinedBaseUrl');
      TrayService.instance.setBaseUrl(determinedBaseUrl);
    } else {
      logger.debug('Login was cancelled or failed. No token stored.');
    }
  };

  final token = await storage.readAccessToken();
  if (token == null) {
    logger.error('No token. Please login first.');
    return;
  }
  final socket = WebitelSocket(
    config: WebitelSocketConfig(url: AppConfig.webitelWsUrl, token: token),
  );
  await socket.connect();
  await socket.authenticate();
  final agent = await socket.getAgentSession();
  await storage.writeAgentId(agent.agentId);

  TrayService.instance.attachSocket(socket);

  // Start screenshots if enabled in config
  if (AppConfig.screenshotEnabled) {
    final screenshotService = ScreenshotSenderService(
      uploadUrl: AppConfig.mediaUploadUrl,
      interval: Duration(seconds: AppConfig.screenshotPeriodicitySec),
    );
    screenshotService.start();
    logger.info(
      'Screenshot service started with interval ${AppConfig.screenshotPeriodicitySec} seconds.',
    );
  }

  runApp(const MyApp());
}
