import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/login.dart';
import 'package:webitel_agent_flutter/presentation/page/main.dart';
import 'package:webitel_agent_flutter/presentation/page/missing_config.dart';
import 'package:webitel_agent_flutter/screenshot.dart';
import 'package:webitel_agent_flutter/storage.dart';
import 'package:webitel_agent_flutter/tray.dart';
import 'package:webitel_agent_flutter/webrtc/core/config.dart';
import 'package:webitel_agent_flutter/webrtc/session/stream_recorder.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';
import 'package:webitel_agent_flutter/ws/ws_config.dart';

import 'config/config.dart';
import 'config/model/config.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _startAppFlow();
}

Future<void> _startAppFlow() async {
  // final screenCaptureAllowed = await checkAndRequestScreenCapturePermission();
  // if (!screenCaptureAllowed) {
  //   logger.warn(
  //     'Screen capture permission denied or not granted. Exiting app.',
  //   );
  //   return;
  // }

  AppConfigModel? config;

  config = await AppConfig.load();
  await logger.init(config);
  await TrayService.instance.initTray();

  if (config != null) {
    runApp(const MyApp());
  } else {
    runApp(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: MissingConfigPage(),
      ),
    );

    TrayService.instance.onConfigUploaded = () async {
      try {
        final uploadedConfig = await AppConfig.load();
        if (uploadedConfig == null) {
          logger.error('Loaded config is still null after upload');
          return;
        }

        await logger.init(uploadedConfig);
        await _restartAppFlow();
      } catch (e) {
        logger.error('Failed to load config after upload: $e');
      }
    };
  }
}

Future<void> _restartAppFlow() async {
  runApp(const MyApp());
}

/// Top-level app widget
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Delay app logic until the UI is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      appStartupFlow();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const MainPage(),
    );
  }
}

/// Checks for macOS screen capture permission
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

/// Waits for the navigator to be available
Future<void> waitForNavigator() async {
  while (navigatorKey.currentState == null) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

/// Handles the login process via WebView
bool _isLoggingIn = false;

Future<bool> performLoginFlow() async {
  if (_isLoggingIn) {
    logger.warn('Login already in progress, skipping duplicate call.');
    return false;
  }

  _isLoggingIn = true;

  try {
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      logger.error('NavigatorState is null, cannot open LoginWebView');
      return false;
    }

    final result = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => LoginWebView(url: AppConfig.instance.loginUrl),
      ),
    );

    if (result == true) {
      final token = await SecureStorageService().readAccessToken();
      if (token != null && token.isNotEmpty) {
        final uri = Uri.parse(AppConfig.instance.loginUrl);
        final baseUrl =
            '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        TrayService.instance.setBaseUrl(baseUrl);
        return true;
      }
    }

    return false;
  } finally {
    _isLoggingIn = false;
  }
}

/// Main startup logic: login, init socket, start services
Future<void> appStartupFlow() async {
  final storage = SecureStorageService();
  //
  // final screenCaptureAllowed = await checkAndRequestScreenCapturePermission();
  // if (!screenCaptureAllowed) {
  //   logger.warn(
  //     'Screen capture permission denied or not granted. Exiting app.',
  //   );
  //   return;
  // }

  String? token = await storage.readAccessToken();

  if (token != null) {
    if (token.isEmpty) {
      await waitForNavigator();

      final loggedIn = await performLoginFlow();
      if (!loggedIn) {
        logger.warn('Login cancelled. User stays logged out.');
        return;
      }

      token = await storage.readAccessToken();
      if (token!.isEmpty) {
        logger.error('Token missing after login flow!');
        return;
      }
    }
  }

  await initialize(token ?? '');
}

/// Initializes WebSocket, tray, services, and WebRTC stream handlers
Future<void> initialize(String token) async {
  final storage = SecureStorageService();

  final socket = WebitelSocket(
    config: WebitelSocketConfig(
      url: AppConfig.instance.webitelWsUrl,
      mediaUploadUrl: AppConfig.instance.mediaUploadUrl,
      token: token,
    ),
  );

  await socket.connect();

  Future<bool> authenticateSocket() async {
    try {
      await socket.authenticate();
      return true;
    } catch (e, stack) {
      logger.error('Socket authentication error: $e', stack);
      return false;
    }
  }

  socket.onAuthenticationFailed = () async {
    logger.warn('Socket authentication failed, relogin required');
    await storage.deleteAccessToken();

    await waitForNavigator();
    final success = await performLoginFlow();

    if (!success) {
      logger.warn('Re-login failed or canceled.');
      return;
    }

    final newToken = await storage.readAccessToken();
    if (newToken == null || newToken.isEmpty) {
      logger.error('Token missing after re-login.');
      return;
    }

    socket.updateToken(newToken);

    final auth = await authenticateSocket();
    if (!auth) {
      logger.error('Re-authentication failed after token update.');
    }
  };

  final authSuccess = await authenticateSocket();
  if (!authSuccess) {
    logger.error('Initial authentication failed.');
    return;
  }

  final agent = await socket.getAgentSession();
  await storage.writeAgentId(agent.agentId);

  TrayService.instance.attachSocket(socket);

  StreamRecorder? webrtcStream;

  socket.onCallEvent(
    onRinging: (callId) async {
      webrtcStream?.stop();

      final webrtcConfig = WebRTCConfig.fromEnv();

      webrtcStream = StreamRecorder(
        callID: callId,
        token: token,
        sdpResolverUrl: webrtcConfig.sdpUrl,
        iceServers: AppConfig.instance.webrtcIceServers,
      );

      try {
        await webrtcStream?.start();
      } catch (e) {
        logger.error('Failed to start WebRTC stream: $e');
      }
    },
    onHangup: (callId) {
      webrtcStream?.stop();
      webrtcStream = null;
    },
  );

  socket.onScreenRecordEvent(
    onStart: (body) async {
      webrtcStream?.stop(); // in case something's already running

      final webrtcConfig = WebRTCConfig.fromEnv();

      webrtcStream = StreamRecorder(
        callID: body['root_id'] ?? 'unknown_recording',
        token: token,
        sdpResolverUrl: webrtcConfig.sdpUrl,
        iceServers: AppConfig.instance.webrtcIceServers,
      );

      try {
        await webrtcStream?.start();
      } catch (e) {
        logger.error('Failed to start screen recording stream: $e');
      }
    },
    onStop: (body) {
      webrtcStream?.stop();
      webrtcStream = null;
    },
  );

  if (AppConfig.instance.screenshotEnabled) {
    final screenshotService = ScreenshotSenderService(
      uploadUrl: AppConfig.instance.mediaUploadUrl,
    );
    screenshotService.start();
  }
}
