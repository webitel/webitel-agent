import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webitel_agent_flutter/storage.dart';

import 'logger.dart';

class LoginWebView extends StatefulWidget {
  final String url;

  const LoginWebView({super.key, required this.url});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  final _storage = SecureStorageService();

  @override
  void initState() {
    super.initState();
  }

  Future<void> _handleTokenFromUri(Uri uri) async {
    logger.debug('Checking URI for accessToken: $uri');
    logger.debug('Full URI query parameters: ${uri.queryParameters}');

    final token = uri.queryParameters['accessToken'];

    if (token != null && token.isNotEmpty) {
      logger.debug('Found token: $token');
      await _storage.writeAccessToken(token);
      logger.info('Logged in. Token stored.');

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } else {
      logger.debug('No valid accessToken found in URI.');
      if (token == null) logger.debug('Reason: token is null.');
      if (token?.isEmpty ?? false) logger.debug('Reason: token is empty.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
        onWebViewCreated: (controller) {
          // No controller stored, so no logs here
        },
        onLoadStop: (controller, url) async {
          logger.debug('Page finished loading: $url');

          if (url != null) {
            final uri = Uri.parse(url.toString());
            await _handleTokenFromUri(uri);
          }
        },
        onNavigationResponse: (controller, navigationResponse) async {
          final url = navigationResponse.response?.url;
          if (url != null) {
            final uri = Uri.parse(url.toString());
            await _handleTokenFromUri(uri);
            return NavigationResponseAction.CANCEL;
          }

          return NavigationResponseAction.ALLOW;
        },
        onReceivedError: (controller, request, error) {
          logger.error(
            'WebView Error: URL=${request.url} Description=${error.description}',
          );
        },
        onReceivedHttpError: (controller, request, response) {
          logger.error(
            'WebView HTTP Error: URL=${request.url} StatusCode=${response.statusCode} ReasonPhrase=${response.reasonPhrase}',
          );
        },
        onConsoleMessage: (controller, consoleMessage) {
          logger.debug('WEB CONSOLE: ${consoleMessage.message}');
        },
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
