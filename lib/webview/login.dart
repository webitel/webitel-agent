import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/presentation/theme/defaults.dart';
import 'package:webitel_desk_track/presentation/theme/text_style.dart';

class LoginWebView extends StatefulWidget {
  final String url;
  final IStorageService storage;

  const LoginWebView({super.key, required this.url, required this.storage});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
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
                await _handleToken(controller, Uri.parse(url.toString()));
              }
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final uri = navigationAction.request.url;
              if (uri != null &&
                  !_tokenHandled &&
                  navigationAction.isForMainFrame) {
                await _handleToken(controller, uri);
                if (_tokenHandled) return NavigationActionPolicy.CANCEL;
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

  // web-client-auth no longer appends accessToken to the redirect URL
  // (WTEL-10705); it only stores it in localStorage before leaving /app/auth.
  Future<void> _handleToken(InAppWebViewController controller, Uri uri) async {
    var token = uri.queryParameters['accessToken'];
    if ((token == null || token.isEmpty) && !_isAuthPage(uri)) {
      token = await _readTokenFromLocalStorage(controller);
    }
    if (token == null || token.isEmpty) return;

    _tokenHandled = true;
    try {
      await widget.storage.writeAccessToken(token);
      logger.info('Token saved successfully.');

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      _tokenHandled = false;
      logger.error('Failed to save token: $e\n$st');
    }
  }

  bool _isAuthPage(Uri uri) => uri.path.startsWith('/app/auth');

  Future<String?> _readTokenFromLocalStorage(
    InAppWebViewController controller,
  ) async {
    try {
      final value = await controller.evaluateJavascript(
        source: "window.localStorage.getItem('access-token')",
      );
      if (value is String && value.isNotEmpty && value != 'undefined') {
        return value;
      }
    } catch (e) {
      logger.warn('Failed to read access-token from WebView localStorage: $e');
    }
    return null;
  }
}
