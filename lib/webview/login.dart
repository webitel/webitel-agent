import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webitel_desk_track/core/logger.dart';
import 'package:webitel_desk_track/presentation/theme/defaults.dart';
import 'package:webitel_desk_track/presentation/theme/text_style.dart';
import 'package:webitel_desk_track/storage/storage.dart';

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
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('${widget.url}/app/auth'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              useShouldOverrideUrlLoading: true,
              clearCache: true,
              cacheEnabled: false,
              allowsInlineMediaPlayback: true,
              useOnLoadResource: true,
            ),
            onWebViewCreated: (controller) {
              _controller = controller;
            },
            onLoadStart: (controller, url) {
              _loading = true;
              setState(() {});
            },
            onLoadStop: (controller, url) async {
              _loading = false;
              _hasError = false;
              setState(() {});

              if (url != null && !_tokenHandled) {
                await _handleTokenFromUri(Uri.parse(url.toString()));
              }
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final uri = navigationAction.request.url;
              if (uri != null && !_tokenHandled) {
                await _handleTokenFromUri(uri);
              }
              return NavigationActionPolicy.ALLOW;
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

          if (_loading) const Center(child: CircularProgressIndicator()),

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
                      Defaults.captureTitle,
                      style: AppTextStyles.captureTitle,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      Defaults.captureSubtitle,
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

      try {
        await _storage.writeAccessToken(token);
        logger.info('Token saved successfully.');

        if (mounted) {
          Navigator.of(context).pop(true);
        }
      } catch (e, st) {
        logger.error('Failed to save token: $e\n$st');
      }
    }
  }
}
