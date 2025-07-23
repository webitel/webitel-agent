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
        },
        onNavigationResponse: (controller, navigationResponse) async {
          final url = navigationResponse.response?.url;
          if (url != null) {
            final uri = Uri.parse(url.toString());
            logger.debug('Navigation Response URL: $uri');
            logger.debug('Full URI query parameters: ${uri.queryParameters}');

            String? tokenFromUrl;

            final bool hasAccessTokenKey = uri.queryParameters.containsKey(
              'accessToken',
            );
            logger.debug(
              'Does queryParameters contain "accessToken" key? $hasAccessTokenKey',
            );

            if (hasAccessTokenKey) {
              tokenFromUrl = uri.queryParameters['accessToken'];
              logger.debug(
                'Value of accessToken from queryParameters: $tokenFromUrl',
              );
            }

            final bool isTokenNull = tokenFromUrl == null;
            final bool isTokenEmpty = tokenFromUrl?.isEmpty ?? true;
            logger.debug('Is tokenFromUrl null? $isTokenNull');
            logger.debug('Is tokenFromUrl empty? $isTokenEmpty');

            if (tokenFromUrl != null && tokenFromUrl.isNotEmpty) {
              logger.debug(
                'Conditions met: Processing token and attempting to pop WebView.',
              );

              await _storage.writeAccessToken(tokenFromUrl);
              logger.info('Logged in. Token stored.');

              if (mounted) {
                if (tokenFromUrl != null && tokenFromUrl.isNotEmpty) {
                  await _storage.writeAccessToken(tokenFromUrl);
                  logger.info('Logged in. Token stored.');

                  if (mounted) {
                    Navigator.of(context).pop(true);
                  }
                  return NavigationResponseAction.CANCEL;
                }
              }
              return NavigationResponseAction.CANCEL; // Stop navigation
            } else {
              logger.debug('Token NOT processed.');
              if (tokenFromUrl == null) {
                logger.debug('Reason: tokenFromUrl is null.');
              } else if (tokenFromUrl.isEmpty) {
                logger.debug('Reason: tokenFromUrl is empty.');
              }
            }
          }
          return NavigationResponseAction.ALLOW; // Allow normal navigation
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
