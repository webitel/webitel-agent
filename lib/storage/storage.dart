import 'package:shared_preferences/shared_preferences.dart';

class SecureStorageService {
  SecureStorageService._internal();

  static final SecureStorageService _instance =
      SecureStorageService._internal();

  factory SecureStorageService() => _instance;

  /// Writes the access token to storage (plain text).
  Future<void> writeAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
  }

  /// Reads the access token from storage (plain text).
  Future<String?> readAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('token');
  }

  /// Deletes the access token from storage.
  Future<void> deleteAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }

  /// Writes the agent ID (not encrypted).
  Future<void> writeAgentId(int agentId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('agent_id', agentId);
  }

  /// Reads the agent ID (not encrypted).
  Future<int?> readAgentId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('agent_id');
  }

  /// Deletes the agent ID.
  Future<void> deleteAgentId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('agent_id');
  }

  /// Clears all stored data from SharedPreferences.
  /// Used on logout or full app reset.
  Future<void> flush() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}

// import 'dart:io';
// import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
// import 'package:shared_preferences/shared_preferences.dart';

// class SecureStorageService {
//   SecureStorageService._internal();

//   static final SecureStorageService _instance =
//       SecureStorageService._internal();

//   factory SecureStorageService() => _instance;

//   // Secure storage for mobile / macOS / Linux
//   final FlutterSecureStorage? _storage =
//       (Platform.isMacOS ||
//               Platform.isLinux ||
//               Platform.isIOS ||
//               Platform.isAndroid)
//           ? const FlutterSecureStorage()
//           : null;

//   // Secure storage for Windows
//   final FlutterSecureStorageWindows? _windowsStorage =
//       Platform.isWindows ? FlutterSecureStorageWindows() : null;

//   // Windows specific options
//   final Map<String, String> _windowsOptions = {
//     'useBackwardCompatibility': 'false',
//   };

//   /// ------------------------
//   /// Token management
//   /// ------------------------

//   Future<void> writeAccessToken(String token) async {
//     if (Platform.isWindows) {
//       await _windowsStorage?.write(
//         key: 'token',
//         value: token,
//         options: _windowsOptions,
//       );
//     } else {
//       await _storage?.write(key: 'token', value: token);
//     }
//   }

//   Future<String?> readAccessToken() async {
//     if (Platform.isWindows) {
//       return await _windowsStorage?.read(
//         key: 'token',
//         options: _windowsOptions,
//       );
//     } else {
//       return await _storage?.read(key: 'token');
//     }
//   }

//   Future<void> deleteAccessToken() async {
//     if (Platform.isWindows) {
//       await _windowsStorage?.delete(key: 'token', options: _windowsOptions);
//     } else {
//       await _storage?.delete(key: 'token');
//     }
//   }

//   /// ------------------------
//   /// AGENT ID management
//   /// ------------------------

//   Future<void> writeAgentId(int agentId) async {
//     final prefs = await SharedPreferences.getInstance();
//     await prefs.setInt('agent_id', agentId);
//   }

//   Future<int?> readAgentId() async {
//     final prefs = await SharedPreferences.getInstance();
//     return prefs.getInt('agent_id');
//   }

//   Future<void> deleteAgentId() async {
//     final prefs = await SharedPreferences.getInstance();
//     await prefs.remove('agent_id');
//   }
// }
