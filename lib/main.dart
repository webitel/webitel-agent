import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

import 'config.dart';
import 'login.dart';
import 'storage.dart';
import 'tray.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  await TrayService.instance.initTray();

  TrayService.instance.onLogin = () async {
    debugPrint('TrayService: Login initiated. Launching WebView...');
    await navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
    );

    debugPrint('LoginWebView has closed. Checking login status...');
    final token = await SecureStorageService().readAccessToken();

    if (token != null) {
      debugPrint('Login successful. Token found.');

      final Uri loginUri = Uri.parse(AppConfig.loginUrl);
      final String determinedBaseUrl =
          '${loginUri.scheme}://${loginUri.host}${loginUri.hasPort ? ':${loginUri.port}' : ''}';

      debugPrint('Determined Base URL for API calls: $determinedBaseUrl');
      TrayService.instance.setBaseUrl(determinedBaseUrl);
    } else {
      debugPrint('Login was cancelled or failed. No token stored.');
    }
  };

  runApp(const MyApp());
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  WebitelSocket? _socket;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Tray App Running'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final token = await SecureStorageService().readAccessToken();
                  if (token == null) {
                    debugPrint('❌ No token. Please login first.');
                    return;
                  }

                  debugPrint('Connecting to WebSocket...');
                  final socket = WebitelSocket(token);
                  await socket.connect();
                  setState(() {
                    _socket = socket;
                  });
                  debugPrint('✅ WebSocket connected.');
                },
                child: const Text("Connect to ws"),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  if (_socket == null) {
                    debugPrint('⚠️ Please connect to the WebSocket first.');
                    return;
                  }

                  try {
                    final auth = await _socket!.authenticate();
                    debugPrint(
                      '✅ Authorized as ${auth.authorizationUser} (${auth.displayName})',
                    );
                  } catch (e) {
                    debugPrint('❌ Auth failed: $e');
                  }
                },
                child: const Text("Authorize"),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  if (_socket == null) {
                    debugPrint('⚠️ Please connect to the WebSocket first.');
                    return;
                  }

                  try {
                    final agent = await _socket!.getAgentSession();
                    debugPrint('✅ Agent: $agent');
                  } catch (e) {
                    debugPrint('❌ agent fetch failed: $e');
                  }
                },
                child: const Text("Get agent"),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  if (_socket == null) {
                    debugPrint('⚠️ Please connect to the WebSocket first.');
                    return;
                  }

                  try {
                    final device = await _socket!.getUserDefaultDevice();
                    debugPrint('✅ Device: $device');
                  } catch (e) {
                    debugPrint('❌ device fetch failed: $e');
                  }
                },
                child: const Text("Get device"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
