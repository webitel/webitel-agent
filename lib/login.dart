// login.dart
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LoginWebView extends StatefulWidget {
  final String url;

  const LoginWebView({super.key, required this.url});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  final _storage = const FlutterSecureStorage();

  // Removed bool _isTokenProcessing = false;

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
          // _controller removed, no need to store it
        },
        onLoadStop: (controller, url) async {
          debugPrint('Page finished loading: $url');
        },
        onNavigationResponse: (controller, navigationResponse) async {
          final url = navigationResponse.response?.url;
          if (url != null) {
            final uri = Uri.parse(url.toString());
            debugPrint('Navigation Response URL: $uri');
            debugPrint(
              'DEBUG: Full URI query parameters: ${uri.queryParameters}',
            );

            String? tokenFromUrl;

            final bool hasAccessTokenKey = uri.queryParameters.containsKey(
              'accessToken',
            );
            debugPrint(
              'DEBUG: Does queryParameters contain "accessToken" key? $hasAccessTokenKey',
            );

            if (hasAccessTokenKey) {
              tokenFromUrl = uri.queryParameters['accessToken'];
              debugPrint(
                'DEBUG: Value of accessToken from queryParameters: $tokenFromUrl',
              );
            }

            final bool isTokenNull = tokenFromUrl == null;
            final bool isTokenEmpty = tokenFromUrl?.isEmpty ?? true;
            debugPrint('DEBUG: Is tokenFromUrl null? $isTokenNull');
            debugPrint('DEBUG: Is tokenFromUrl empty? $isTokenEmpty');

            // The main condition simplified: only check if token is valid
            if (tokenFromUrl != null && tokenFromUrl.isNotEmpty) {
              debugPrint(
                'DEBUG: Conditions met: Processing token and attempting to pop WebView.',
              );

              await _storage.write(key: 'token', value: tokenFromUrl);
              debugPrint('Logged in. Token stored: $tokenFromUrl');

              if (mounted) {
                Navigator.of(context).pop(); // HIDES THE WEBVIEW!
              }
              return NavigationResponseAction.CANCEL; // Stop navigation
            } else {
              debugPrint('DEBUG: Token NOT processed.');
              if (tokenFromUrl == null) {
                debugPrint('DEBUG: Reason: tokenFromUrl is null.');
              } else if (tokenFromUrl.isEmpty) {
                debugPrint('DEBUG: Reason: tokenFromUrl is empty.');
              }
            }
          }
          return NavigationResponseAction.ALLOW; // Allow normal navigation
        },
        onReceivedError: (controller, request, error) {
          debugPrint('WebView Error:');
          debugPrint('  URL: ${request.url}');
          debugPrint('  Description: ${error.description}');
        },
        onReceivedHttpError: (controller, request, response) {
          debugPrint('WebView HTTP Error:');
          debugPrint('  URL: ${request.url}');
          debugPrint('  Status Code: ${response.statusCode}');
          debugPrint('  Reason Phrase: ${response.reasonPhrase}');
        },
        onConsoleMessage: (controller, consoleMessage) {
          debugPrint('WEB CONSOLE: ${consoleMessage.message}');
        },
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

// // login.dart
// import 'package:flutter/material.dart';
// import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// import 'package:flutter_secure_storage/flutter_secure_storage.dart';
//
// class LoginWebView extends StatefulWidget {
//   final String url;
//
//   const LoginWebView({super.key, required this.url});
//
//   @override
//   State<LoginWebView> createState() => _LoginWebViewState();
// }
//
// class _LoginWebViewState extends State<LoginWebView> {
//   final _storage = const FlutterSecureStorage();
//   bool _isTokenProcessing = false;
//
//   @override
//   void initState() {
//     super.initState();
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       body: InAppWebView(
//         initialUrlRequest: URLRequest(url: WebUri(widget.url)),
//         initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
//         onWebViewCreated: (controller) {},
//         onLoadStop: (controller, url) async {
//           debugPrint('Page finished loading: $url');
//         },
//         onNavigationResponse: (controller, navigationResponse) async {
//           final url = navigationResponse.response?.url;
//           if (url != null) {
//             final uri = Uri.parse(url.toString());
//             debugPrint('Navigation Response URL: $uri');
//             debugPrint(
//               'DEBUG: Full URI query parameters: ${uri.queryParameters}',
//             ); // NEW: Print all query params
//
//             String? tokenFromUrl;
//
//             // Check if 'accessToken' key exists in the parsed query parameters
//             final bool hasAccessTokenKey = uri.queryParameters.containsKey(
//               'accessToken',
//             );
//             debugPrint(
//               'DEBUG: Does queryParameters contain "accessToken" key? $hasAccessTokenKey',
//             ); // NEW: Check key existence
//
//             if (hasAccessTokenKey) {
//               tokenFromUrl = uri.queryParameters['accessToken'];
//               debugPrint(
//                 'DEBUG: Value of accessToken from queryParameters: $tokenFromUrl',
//               ); // NEW: Print the extracted value
//             }
//
//             // After attempting to extract the token, check its state
//             final bool isTokenNull = tokenFromUrl == null;
//             final bool isTokenEmpty =
//                 tokenFromUrl?.isEmpty ?? true; // True if null or empty
//             debugPrint(
//               'DEBUG: Is tokenFromUrl null? $isTokenNull',
//             ); // NEW: Check if null
//             debugPrint(
//               'DEBUG: Is tokenFromUrl empty? $isTokenEmpty',
//             ); // NEW: Check if empty
//
//             // This block processes the token and pops the WebView
//             if (!_isTokenProcessing &&
//                 tokenFromUrl != null &&
//                 tokenFromUrl.isNotEmpty) {
//               _isTokenProcessing =
//                   true; // Set flag to true immediately upon entering
//               debugPrint(
//                 'DEBUG: Conditions met: Processing token and attempting to pop WebView.',
//               ); // Add debug print
//
//               await _storage.write(key: 'token', value: tokenFromUrl);
//               debugPrint('Logged in. Token stored: $tokenFromUrl');
//
//               if (mounted) {
//                 Navigator.of(context).pop(); // HIDES THE WEBVIEW!
//               }
//               return NavigationResponseAction.CANCEL; // Stop navigation
//             } else {
//               // This else block will catch why the token wasn't processed
//               debugPrint('DEBUG: Token NOT processed.');
//               if (_isTokenProcessing) {
//                 debugPrint(
//                   'DEBUG: Reason: _isTokenProcessing was already true.',
//                 );
//               } else if (tokenFromUrl == null) {
//                 debugPrint('DEBUG: Reason: tokenFromUrl is null.');
//               } else if (tokenFromUrl.isEmpty) {
//                 debugPrint('DEBUG: Reason: tokenFromUrl is empty.');
//               }
//             }
//           }
//           return NavigationResponseAction.ALLOW; // Allow normal navigation
//         },
//         onReceivedError: (controller, request, error) {
//           debugPrint('WebView Error:');
//           debugPrint('  URL: ${request.url}');
//           debugPrint('  Description: ${error.description}');
//         },
//         onReceivedHttpError: (controller, request, response) {
//           debugPrint('WebView HTTP Error:');
//           debugPrint('  URL: ${request.url}');
//           debugPrint('  Status Code: ${response.statusCode}');
//           debugPrint('  Reason Phrase: ${response.reasonPhrase}');
//         },
//         onConsoleMessage: (controller, consoleMessage) {
//           debugPrint('WEB CONSOLE: ${consoleMessage.message}');
//         },
//       ),
//     );
//   }
//
//   @override
//   void dispose() {
//     // No explicit timer to cancel here, cleanup handled by widget lifecycle
//     super.dispose();
//   }
// }
