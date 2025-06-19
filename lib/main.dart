import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_agent_flutter/presentation/main.dart';
import 'package:webitel_agent_flutter/screenshot.dart';
import 'package:webitel_agent_flutter/webrtc/config.dart';
import 'package:webitel_agent_flutter/webrtc/stream_sender.dart';
import 'package:webitel_agent_flutter/ws/config.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

import 'config.dart';
import 'logger.dart';
import 'login.dart';
import 'storage.dart';
import 'tray.dart';

Future<bool> performLoginFlow() async {
  final logger = LoggerService();
  final storage = SecureStorageService();

  logger.debug('Launching login WebView...');
  await navigatorKey.currentState?.push(
    MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
  );

  final token = await storage.readAccessToken();
  if (token != null && token.isNotEmpty) {
    final uri = Uri.parse(AppConfig.loginUrl);
    final baseUrl =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    TrayService.instance.setBaseUrl(baseUrl);
    return true;
  }
  logger.debug('Login canceled or failed');
  return false;
}

Future<bool> checkAndRequestScreenCapturePermission() async {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    final allowed = await ScreenCapturer.instance.isAccessAllowed();
    if (!allowed) {
      await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
      logger.warn(
        'Screen capture access not yet granted. User must enable it in System Preferences.',
      );
      return false;
    }
  }
  return true;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  final logger = LoggerService();
  final storage = SecureStorageService();

  await TrayService.instance.initTray();

  final screenCaptureAllowed = await checkAndRequestScreenCapturePermission();
  if (!screenCaptureAllowed) {
    logger.warn(
      'Screen capture permission denied or not yet granted. Exiting app.',
    );
    return;
  }

  TrayService.instance.onLogin = () async {
    await performLoginFlow();
  };

  String? token = await storage.readAccessToken();

  if (token == null || token.isEmpty) {
    final loginSuccess = await performLoginFlow();
    if (!loginSuccess) {
      logger.warn('Login canceled, launching app with login screen only.');
      runApp(const MyApp()); // Let user log in later via UI
      return;
    }
    token = await storage.readAccessToken();
  }

  runApp(const MyApp()); // UI starts early
  await initialize(token!); // Init services in background after login
}

Future<void> initialize(String token) async {
  final logger = LoggerService();
  final storage = SecureStorageService();

  final socket = WebitelSocket(
    config: WebitelSocketConfig(url: AppConfig.webitelWsUrl, token: token),
  );

  await socket.connect();

  Future<bool> authenticateSocket() async {
    try {
      await socket.authenticate();
      return true;
    } catch (e, stack) {
      logger.error('[WebRTC] Authentication error: $e', stack);
      return false;
    }
  }

  socket.onAuthenticationFailed = () async {
    logger.warn('[WebRTC] Authentication failed, relogin required.');

    await storage.deleteAccessToken();

    final success = await performLoginFlow();
    if (!success) return;

    final newToken = await storage.readAccessToken();
    if (newToken == null || newToken.isEmpty) return;

    socket.updateToken(newToken);
    final auth = await authenticateSocket();
    if (!auth) return;
  };

  final authSuccess = await authenticateSocket();
  if (!authSuccess) return;

  final agent = await socket.getAgentSession();
  await storage.writeAgentId(agent.agentId);
  await socket.setOnline(agent.agentId);
  TrayService.instance.attachSocket(socket);

  StreamSender? webrtcStream;

  socket.onCallEvent(
    onRinging: (callId) async {
      logger.info('[WebRTC] Ringing event: $callId');
      if (webrtcStream?.isStreaming == true) {
        webrtcStream?.stop();
      }

      final webrtcConfig = WebRTCConfig.fromEnv();

      webrtcStream = StreamSender(
        id: callId,
        token: token,
        sdpResolverUrl: webrtcConfig.sdpUrl,
        iceServers: AppConfig.webrtcIceServers,
      );

      try {
        await webrtcStream!.start();
        logger.info('[WebRTC] Stream started for $callId');
      } catch (e, stack) {
        logger.error('[WebRTC] Stream start failed: $e', stack);
      }
    },
    onHangup: (callId) {
      logger.info('[WebRTC] Hangup: $callId');
      if (webrtcStream?.isStreaming == true) {
        webrtcStream?.stop();
        webrtcStream = null;
      }
    },
  );

  if (AppConfig.screenshotEnabled) {
    final screenshotService = ScreenshotSenderService(
      uploadUrl: AppConfig.mediaUploadUrl,
      interval: Duration(seconds: AppConfig.screenshotPeriodicitySec),
    );
    screenshotService.start();
  }
}
