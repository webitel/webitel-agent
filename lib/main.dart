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

/// Main entry point for the Webitel Agent application
/// --------------------------------------------------
/// Initializes core services, handles authentication,
/// and starts background processes before launching UI.
void main() async {
  // Initialize Flutter engine bindings
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables from .env file
  await dotenv.load(fileName: ".env");

  // Initialize application logger
  final logger = LoggerService();

  // Initialize secure storage for tokens and credentials
  final storage = SecureStorageService();

  // ------------------------------
  // SYSTEM TRAY INITIALIZATION
  // ------------------------------
  await TrayService.instance.initTray();

  /// Tray Login Callback
  /// -------------------
  /// Handles login initiation from system tray menu
  TrayService.instance.onLogin = () async {
    logger.debug('TrayService: Login initiated. Launching WebView...');

    // Navigate to login web view
    await navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
    );

    logger.debug('LoginWebView closed. Checking login status...');
    final token = await storage.readAccessToken();

    if (token != null) {
      logger.debug('Login successful. Token found.');

      // Derive base URL from login URL
      final Uri loginUri = Uri.parse(AppConfig.loginUrl);
      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      logger.debug('API Base URL determined: $determinedBaseUrl');
      TrayService.instance.setBaseUrl(determinedBaseUrl);
    } else {
      logger.debug('Login canceled or failed. No token stored.');
    }
  };

  // ------------------------------
  // AUTHENTICATION CHECK
  // ------------------------------
  final token = await storage.readAccessToken();
  if (token == null) {
    logger.error('No authentication token found. User must login first.');
    return;
  }

  // ------------------------------
  // WEBSOCKET CONNECTION SETUP
  // ------------------------------
  final socket = WebitelSocket(
    config: WebitelSocketConfig(url: AppConfig.webitelWsUrl, token: token),
  );

  // Establish WebSocket connection
  await socket.connect();

  // Authenticate with Webitel services
  await socket.authenticate();

  // Retrieve agent session information
  final agent = await socket.getAgentSession();

  // Store agent ID for future use
  await storage.writeAgentId(agent.agentId);

  // Set agent status to online
  await socket.setOnline(agent.agentId);

  // Attach socket to tray service for status updates
  TrayService.instance.attachSocket(socket);

  // ------------------------------
  // SCREENSHOT SERVICE (OPTIONAL)
  // ------------------------------
  if (AppConfig.screenshotEnabled) {
    logger.info('Initializing screenshot service...');

    final screenshotService = ScreenshotSenderService(
      uploadUrl: AppConfig.mediaUploadUrl,
      interval: Duration(seconds: AppConfig.screenshotPeriodicitySec),
    );

    // Start periodic screenshot capturing
    screenshotService.start();

    logger.info(
      'Screenshot service active (Interval: ${AppConfig.screenshotPeriodicitySec} seconds)',
    );
  }

  // ------------------------------
  // APPLICATION LAUNCH
  // ------------------------------
  runApp(const MyApp());
}
