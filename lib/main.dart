import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:webitel_agent_flutter/config.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/login.dart';
import 'package:webitel_agent_flutter/presentation/page/main.dart';
import 'package:webitel_agent_flutter/screenshot.dart';
import 'package:webitel_agent_flutter/storage.dart';
import 'package:webitel_agent_flutter/tray.dart';
import 'package:webitel_agent_flutter/webrtc/core/config.dart';
import 'package:webitel_agent_flutter/webrtc/session/stream_recorder.dart';
import 'package:webitel_agent_flutter/ws/config.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await TrayService.instance.initTray();

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
  final logger = LoggerService();
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
Future<bool> performLoginFlow() async {
  final logger = LoggerService();
  final storage = SecureStorageService();

  final navigator = navigatorKey.currentState;
  if (navigator == null) {
    logger.error('NavigatorState is null, cannot open LoginWebView');
    return false;
  }

  final result = await navigator.push<bool>(
    MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
  );

  if (result == true) {
    final token = await storage.readAccessToken();
    if (token != null && token.isNotEmpty) {
      final uri = Uri.parse(AppConfig.loginUrl);
      final baseUrl =
          '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      TrayService.instance.setBaseUrl(baseUrl);
      return true;
    }
  }

  return false;
}

/// Main startup logic: login, init socket, start services
Future<void> appStartupFlow() async {
  final logger = LoggerService();
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

  if (token == null || token.isEmpty) {
    await waitForNavigator();

    final loggedIn = await performLoginFlow();
    if (!loggedIn) {
      logger.warn('Login cancelled. User stays logged out.');
      return;
    }

    token = await storage.readAccessToken();
    if (token == null || token.isEmpty) {
      logger.error('Token missing after login flow!');
      return;
    }
  }

  await initialize(token);
}

/// Initializes WebSocket, tray, services, and WebRTC stream handlers
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

  TrayService.instance.updateStatus('online');
  TrayService.instance.attachSocket(socket);

  StreamRecorder? webrtcStream;

  socket.onCallEvent(
    onRinging: (callId) async {
      webrtcStream?.stop();

      final webrtcConfig = WebRTCConfig.fromEnv();

      webrtcStream = StreamRecorder(
        id: callId,
        token: token,
        sdpResolverUrl: webrtcConfig.sdpUrl,
        iceServers: AppConfig.webrtcIceServers,
      );

      try {
        await webrtcStream?.start();
      } catch (e, stack) {
        logger.error('Failed to start WebRTC stream: $e', stack);
      }
    },
    onHangup: (callId) {
      webrtcStream?.stop();
      webrtcStream = null;
    },
  );

  if (AppConfig.screenshotEnabled) {
    final screenshotService = ScreenshotSenderService(
      uploadUrl: AppConfig.mediaUploadUrl,
    );
    screenshotService.start();
  }
}

// import 'dart:async';
//
// import 'package:flutter/foundation.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter_dotenv/flutter_dotenv.dart';
// import 'package:screen_capturer/screen_capturer.dart';
// import 'package:webitel_agent_flutter/config.dart';
// import 'package:webitel_agent_flutter/logger.dart';
// import 'package:webitel_agent_flutter/login.dart';
// import 'package:webitel_agent_flutter/presentation/page/main.dart';
// import 'package:webitel_agent_flutter/screenshot.dart';
// import 'package:webitel_agent_flutter/storage.dart';
// import 'package:webitel_agent_flutter/tray.dart';
// import 'package:webitel_agent_flutter/webrtc/core/config.dart';
// import 'package:webitel_agent_flutter/webrtc/session/stream_recorder.dart';
// import 'package:webitel_agent_flutter/ws/config.dart';
// import 'package:webitel_agent_flutter/ws/ws.dart';
//
// final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
//
// void main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   await dotenv.load(fileName: ".env");
//
//   final logger = LoggerService();
//   final storage = SecureStorageService();
//
//   // -------- Initialize system tray and its menu --------
//   await TrayService.instance.initTray();
//
//   // final screenCaptureAllowed = await checkAndRequestScreenCapturePermission();
//   // if (!screenCaptureAllowed) {
//   //   logger.warn(
//   //     'Screen capture permission denied or not granted. Exiting app.',
//   //   );
//   //   return;
//   // }
//
//   // -------- Perform async startup tasks such as login and service initialization --------
//   await appStartupFlow();
//
//   // -------- Start the main UI --------
//   runApp(MyApp());
// }
//
// Future<bool> checkAndRequestScreenCapturePermission() async {
//   final logger = LoggerService();
//   if (defaultTargetPlatform == TargetPlatform.macOS) {
//     final allowed = await ScreenCapturer.instance.isAccessAllowed();
//     if (!allowed) {
//       await ScreenCapturer.instance.requestAccess(onlyOpenPrefPane: true);
//       logger.warn(
//         'Screen capture access not yet granted. User must enable it in System Preferences.',
//       );
//       return false;
//     }
//   }
//   return true;
// }
//
// // -------- Waits until the navigator is ready for navigation operations --------
// Future<void> waitForNavigator() async {
//   while (navigatorKey.currentState == null) {
//     await Future.delayed(const Duration(milliseconds: 200));
//   }
// }
//
// // -------- Manages the login flow by opening LoginWebView and handling token storage --------
// Future<bool> performLoginFlow() async {
//   final logger = LoggerService();
//   final storage = SecureStorageService();
//
//   final navigator = navigatorKey.currentState;
//   if (navigator == null) {
//     logger.error('NavigatorState is null, cannot open LoginWebView');
//     return false;
//   }
//
//   final result = await navigator.push<bool>(
//     MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
//   );
//
//   if (result == true) {
//     final token = await storage.readAccessToken();
//     if (token != null && token.isNotEmpty) {
//       final uri = Uri.parse(AppConfig.loginUrl);
//       final baseUrl =
//           '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
//       TrayService.instance.setBaseUrl(baseUrl);
//       return true;
//     }
//   }
//
//   return false;
// }
//
// // -------- Main app startup logic --------
// // Checks for existing token, triggers login if missing, and initializes services
// Future<void> appStartupFlow() async {
//   final logger = LoggerService();
//   final storage = SecureStorageService();
//
//   String? token = await storage.readAccessToken();
//
//   if (token == null || token.isEmpty) {
//     await waitForNavigator();
//
//     final loggedIn = await performLoginFlow();
//     if (!loggedIn) {
//       logger.warn('Login cancelled. User stays logged out.');
//       return;
//     }
//
//     token = await storage.readAccessToken();
//     if (token == null || token.isEmpty) {
//       logger.error('Token missing after login flow!');
//       return;
//     }
//   }
//
//   await initialize(token);
// }
//
// // -------- Initializes WebSocket, attaches Tray, and starts additional services --------
// Future<void> initialize(String token) async {
//   final logger = LoggerService();
//   final storage = SecureStorageService();
//
//   final socket = WebitelSocket(
//     config: WebitelSocketConfig(url: AppConfig.webitelWsUrl, token: token),
//   );
//
//   await socket.connect();
//
//   // -------- Authenticates the WebSocket connection --------
//   Future<bool> authenticateSocket() async {
//     try {
//       await socket.authenticate();
//       return true;
//     } catch (e, stack) {
//       logger.error('Socket authentication error: $e', stack);
//       return false;
//     }
//   }
//
//   // -------- Handles socket authentication failure and triggers re-login --------
//   socket.onAuthenticationFailed = () async {
//     logger.warn('Socket authentication failed, relogin required');
//
//     await storage.deleteAccessToken();
//
//     await waitForNavigator();
//
//     final success = await performLoginFlow();
//     if (!success) {
//       logger.warn('Re-login failed or canceled.');
//       return;
//     }
//
//     final newToken = await storage.readAccessToken();
//     if (newToken == null || newToken.isEmpty) {
//       logger.error('Token missing after re-login.');
//       return;
//     }
//
//     socket.updateToken(newToken);
//     final auth = await authenticateSocket();
//     if (!auth) {
//       logger.error('Re-authentication failed after token update.');
//       return;
//     }
//   };
//
//   final authSuccess = await authenticateSocket();
//   if (!authSuccess) {
//     logger.error('Initial authentication failed.');
//     return;
//   }
//
//   final agent = await socket.getAgentSession();
//   await storage.writeAgentId(agent.agentId);
//   await socket.setOnline(agent.agentId);
//   TrayService.instance.updateStatus('online');
//
//   // -------- Attach socket to tray for status updates --------
//   TrayService.instance.attachSocket(socket);
//
//   StreamRecorder? webrtcStream;
//
//   // -------- WebRTC call event handling --------
//   socket.onCallEvent(
//     onRinging: (callId) async {
//       if (webrtcStream?.isStreaming == true) {
//         webrtcStream?.stop();
//       }
//
//       final webrtcConfig = WebRTCConfig.fromEnv();
//
//       webrtcStream = StreamRecorder(
//         id: callId,
//         token: token,
//         sdpResolverUrl: webrtcConfig.sdpUrl,
//         iceServers: AppConfig.webrtcIceServers,
//       );
//
//       try {
//         await webrtcStream!.start();
//       } catch (e, stack) {
//         logger.error('Failed to start WebRTC stream: $e', stack);
//       }
//     },
//     onHangup: (callId) {
//       if (webrtcStream?.isStreaming == true) {
//         webrtcStream?.stop();
//         webrtcStream = null;
//       }
//     },
//   );
//
//   // -------- Optionally start screenshot capturing service --------
//   if (AppConfig.screenshotEnabled) {
//     final screenshotService = ScreenshotSenderService(
//       uploadUrl: AppConfig.mediaUploadUrl,
//       interval: Duration(seconds: AppConfig.screenshotPeriodicitySec),
//     );
//     screenshotService.start();
//   }
// }
//
// // -------- Simple main app widget --------
// class MyApp extends StatelessWidget {
//   const MyApp({super.key});
//
//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       navigatorKey: navigatorKey,
//       debugShowCheckedModeBanner: false,
//       home: const MainPage(),
//     );
//   }
// }
