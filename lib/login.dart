// login.dart
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'; // New import
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LoginWebView extends StatefulWidget {
  final String url;

  const LoginWebView({super.key, required this.url});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  // Use InAppWebViewController
  InAppWebViewController? _controller;
  final _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
        onWebViewCreated: (controller) {
          _controller = controller;
          _controller?.addJavaScriptHandler(
            handlerName: 'TokenChannel',
            callback: (args) async {
              final token = args[0];
              if (token != null && token.isNotEmpty) {
                await _storage.write(key: 'token', value: token);
                debugPrint('Logged in. Token stored: $token');
                if (mounted) Navigator.of(context).pop(); // close login screen
              }
            },
          );
        },
        onLoadStop: (controller, url) async {
          await controller.evaluateJavascript(
            source: '''
            (function() {
              const token = localStorage.getItem("access-token");
              if (token) {
                localStorage.setItem("access-token", "");
                // Call the JavaScript handler defined in Flutter
                window.flutter_inappwebview.callHandler('TokenChannel', token);
              }
            })();
          ''',
          );
        },
        onReceivedError: (controller, request, error) {
          debugPrint('WebView Error:');
          debugPrint('  URL: ${request.url}');
          debugPrint('  Description: ${error.description}');
        },
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
