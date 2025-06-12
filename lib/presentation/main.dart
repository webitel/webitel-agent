import 'package:flutter/material.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/ws/ws.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  WebitelSocket? _socket;
  final logger = LoggerService();

  @override
  void initState() {
    super.initState();
  }

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
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  if (_socket == null) {
                    logger.debug('Please connect to the WebSocket first.');
                    return;
                  }

                  try {
                    final auth = await _socket!.authenticate();
                    logger.info(
                      'Authorized as ${auth.authorizationUser} (${auth.displayName})',
                    );
                  } catch (e) {
                    logger.error('Auth failed', e);
                  }
                },
                child: const Text("Authorize"),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  if (_socket == null) {
                    logger.debug('Please connect to the WebSocket first.');
                    return;
                  }

                  try {
                    final device = await _socket!.getUserDefaultDevice();
                    logger.info('Device: $device');
                  } catch (e) {
                    logger.error('Device fetch failed', e);
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
