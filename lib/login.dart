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
  final _logger = LoggerService();

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
          // No controller stored, so no logs here
        },
        onLoadStop: (controller, url) async {
          _logger.debug('Page finished loading: $url');
        },
        onNavigationResponse: (controller, navigationResponse) async {
          final url = navigationResponse.response?.url;
          if (url != null) {
            final uri = Uri.parse(url.toString());
            _logger.debug('Navigation Response URL: $uri');
            _logger.debug('Full URI query parameters: ${uri.queryParameters}');

            String? tokenFromUrl;

            final bool hasAccessTokenKey = uri.queryParameters.containsKey(
              'accessToken',
            );
            _logger.debug(
              'Does queryParameters contain "accessToken" key? $hasAccessTokenKey',
            );

            if (hasAccessTokenKey) {
              tokenFromUrl = uri.queryParameters['accessToken'];
              _logger.debug(
                'Value of accessToken from queryParameters: $tokenFromUrl',
              );
            }

            final bool isTokenNull = tokenFromUrl == null;
            final bool isTokenEmpty = tokenFromUrl?.isEmpty ?? true;
            _logger.debug('Is tokenFromUrl null? $isTokenNull');
            _logger.debug('Is tokenFromUrl empty? $isTokenEmpty');

            if (tokenFromUrl != null && tokenFromUrl.isNotEmpty) {
              _logger.debug(
                'Conditions met: Processing token and attempting to pop WebView.',
              );

              await _storage.writeAccessToken(tokenFromUrl);
              _logger.info('Logged in. Token stored.');

              if (mounted) {
                Navigator.of(context).pop(); // Hide the WebView
              }
              return NavigationResponseAction.CANCEL; // Stop navigation
            } else {
              _logger.debug('Token NOT processed.');
              if (tokenFromUrl == null) {
                _logger.debug('Reason: tokenFromUrl is null.');
              } else if (tokenFromUrl.isEmpty) {
                _logger.debug('Reason: tokenFromUrl is empty.');
              }
            }
          }
          return NavigationResponseAction.ALLOW; // Allow normal navigation
        },
        onReceivedError: (controller, request, error) {
          _logger.error(
            'WebView Error: URL=${request.url} Description=${error.description}',
          );
        },
        onReceivedHttpError: (controller, request, response) {
          _logger.error(
            'WebView HTTP Error: URL=${request.url} StatusCode=${response.statusCode} ReasonPhrase=${response.reasonPhrase}',
          );
        },
        onConsoleMessage: (controller, consoleMessage) {
          _logger.debug('WEB CONSOLE: ${consoleMessage.message}');
        },
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
