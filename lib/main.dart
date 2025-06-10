// main.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'config.dart'; // Assumed to contain AppConfig.loginUrl
import 'login.dart'; // Your LoginWebView
import 'storage.dart'; // Your SecureStorageService
import 'tray.dart'; // Your TrayService

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // load config
  await dotenv.load(fileName: ".env");

  // Initialize TrayService early
  await TrayService.instance.initTray();

  // Set the onLogin callback for TrayService
  // THIS IS THE KEY MODIFICATION
  TrayService.instance.onLogin = () async {
    // Make the callback ASYNC
    debugPrint('TrayService: Login initiated. Launching WebView...');

    // Push the LoginWebView and AWAIT its completion (when it pops)
    await navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
    );

    // *******************************************************************
    // --- EXECUTION RESUMES HERE ONLY AFTER LoginWebView has POPPED ---
    // *******************************************************************

    debugPrint('LoginWebView has closed. Checking login status...');

    // Check if the login was successful (i.e., a token was stored)
    final token = await SecureStorageService().readAccessToken();

    if (token != null) {
      debugPrint('Login successful. Token found.');

      // Derive the base URL from your AppConfig.loginUrl
      final Uri loginUri = Uri.parse(AppConfig.loginUrl);
      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      debugPrint('Determined Base URL for API calls: $determinedBaseUrl');

      // **CALL setBaseUrl HERE**
      TrayService.instance.setBaseUrl(determinedBaseUrl);
      debugPrint('TrayService base URL updated after successful login.');

      // You might also want to update the tray menu immediately to reflect login status
      // (e.g., disable Login, enable Logout, change status text)
      // TrayService.instance._buildMenu(); // This might need to be public or triggered
      // TrayService.instance._setStatus('online'); // Or appropriate logged-in status
    } else {
      debugPrint('Login was cancelled or failed. No token stored.');
    }
  };

  runApp(const MyApp());
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const Scaffold(body: Center(child: Text('Tray App Running'))),
      navigatorKey: navigatorKey,
    );
  }
}
