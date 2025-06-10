import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'config.dart';
import 'login.dart';
import 'tray.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // load config
  await dotenv.load(fileName: ".env");

  //inappwebview -- webitel login
  TrayService.instance.onLogin = () {
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => LoginWebView(url: AppConfig.loginUrl)),
    );
  };

  await TrayService.instance.initTray();
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
