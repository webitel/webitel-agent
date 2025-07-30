import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webitel_agent_flutter/logger.dart';
import 'package:webitel_agent_flutter/presentation/theme/defaults.dart';
import 'package:webitel_agent_flutter/presentation/theme/text_style.dart';
import 'package:webitel_agent_flutter/storage.dart';

class LoginWebView extends StatefulWidget {
  final String url;

  const LoginWebView({super.key, required this.url});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  final _storage = SecureStorageService();
  InAppWebViewController? _controller;

  bool _loading = true;
  bool _hasError = false;
  bool _tokenHandled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
            ),
            onWebViewCreated: (controller) {
              _controller = controller;
            },
            onLoadStop: (controller, url) async {
              _loading = false;
              _hasError = false;
              setState(() {});

              if (url != null && !_tokenHandled) {
                final uri = Uri.parse(url.toString());
                await _handleTokenFromUri(uri);
              }
            },
            onReceivedError: (controller, request, error) {
              if (request.isForMainFrame!) {
                _hasError = true;
                _loading = false;
                setState(() {});
              }

              logger.error(
                'WebView Error: URL=${request.url}, Description=${error.description}',
              );
            },
            onReceivedHttpError: (controller, request, response) {
              if (request.isForMainFrame! && response.statusCode! >= 400) {
                _hasError = true;
                _loading = false;
                setState(() {});
              }

              logger.error(
                'HTTP Error: ${response.statusCode} ${response.reasonPhrase} on ${request.url}',
              );
            },
            onConsoleMessage: (controller, message) {
              logger.debug('WebView console: ${message.message}');
            },
          ),

          // Loading spinner
          if (_loading) const Center(child: CircularProgressIndicator()),

          // Error screen
          if (_hasError)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      Defaults.captureTitle, // e.g., "Something went wrong"
                      style: AppTextStyles.captureTitle,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      Defaults.captureSubtitle,
                      // e.g., "Unable to load the login page"
                      style: AppTextStyles.captureSubtitle,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () {
                        _controller?.reload();
                        setState(() {
                          _hasError = false;
                          _loading = true;
                        });
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handleTokenFromUri(Uri uri) async {
    logger.debug('Checking URI for accessToken: $uri');
    final token = uri.queryParameters['accessToken'];

    if (token != null && token.isNotEmpty) {
      _tokenHandled = true;

      logger.debug('Found token: $token');
      await _storage.writeAccessToken(token);
      logger.info('Token saved. Returning from login screen.');

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } else {
      logger.debug('No accessToken in URI.');
    }
  }
}
