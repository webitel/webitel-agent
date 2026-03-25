import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webitel_desk_track/core/logger/logger.dart';
import 'package:webitel_desk_track/core/storage/interface.dart';
import 'package:webitel_desk_track/presentation/theme/defaults.dart';
import 'package:webitel_desk_track/presentation/theme/text_style.dart';

class LoginWebView extends StatefulWidget {
  final String url;
  final IStorageService storage; // Injected storage interface

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
      appBar: AppBar(
        title: const Text('Login'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('${widget.url}/app/auth'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              useShouldOverrideUrlLoading: true,
              clearCache: true,
              cacheEnabled: false,
              allowsInlineMediaPlayback: true,
            ),
            onWebViewCreated: (controller) {
              _controller = controller;
            },
            onLoadStart: (controller, url) {
              setState(() => _loading = true);
            },
            onLoadStop: (controller, url) async {
              setState(() {
                _loading = false;
                _hasError = false;
              });

              if (url != null && !_tokenHandled) {
                await _handleTokenFromUri(Uri.parse(url.toString()));
              }
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final uri = navigationAction.request.url;
              if (uri != null && !_tokenHandled) {
                final handled = await _handleTokenFromUri(uri);
                if (handled) return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onReceivedError: (controller, request, error) {
              if (request.isForMainFrame == true) {
                setState(() {
                  _hasError = true;
                  _loading = false;
                });
              }
              logger.error(
                '[WebView] Error: ${error.description} on ${request.url}',
              );
            },
            onReceivedHttpError: (controller, request, response) {
              if (request.isForMainFrame == true &&
                  (response.statusCode ?? 0) >= 400) {
                setState(() {
                  _hasError = true;
                  _loading = false;
                });
              }
            },
          ),

          if (_loading) const Center(child: CircularProgressIndicator()),

          if (_hasError) _buildErrorPlaceholder(),
        ],
      ),
    );
  }

  Widget _buildErrorPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
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
                setState(() {
                  _hasError = false;
                  _loading = true;
                });
                _controller?.reload();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  /// Extracts token from URI and saves it via the injected storage.
  /// Returns true if the token was found and handled.
  Future<bool> _handleTokenFromUri(Uri uri) async {
    final token = uri.queryParameters['accessToken'];

    if (token != null && token.isNotEmpty) {
      _tokenHandled = true;
      logger.info('[WebView] Access token intercepted.');

      try {
        await widget.storage.writeAccessToken(token);

        if (mounted) {
          Navigator.of(context).pop(true);
        }
        return true;
      } catch (e, st) {
        logger.error('[WebView] Failed to save token', e, st);
        _tokenHandled = false; // Allow retry if saving failed
      }
    }
    return false;
  }
}
