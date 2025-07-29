import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

class SecureStorageService {
  SecureStorageService._internal();

  static final SecureStorageService _instance =
      SecureStorageService._internal();

  factory SecureStorageService() => _instance;

  /// Writes the access token to storage.
  Future<void> writeAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = Platform.isWindows ? _encryptWindows(token) : token;
    await prefs.setString('token', encoded);
  }

  /// Reads the access token from storage.
  Future<String?> readAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('token');
    if (stored == null) return null;
    return Platform.isWindows ? _decryptWindows(stored) : stored;
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

  /// --- Windows-only encryption using DPAPI ---

  String _encryptWindows(String plainText) {
    final plainBytes = utf8.encode(plainText);
    final inputBlob = _createBlob(plainBytes);
    final outputBlob = calloc<CRYPT_INTEGER_BLOB>();

    final result = CryptProtectData(
      inputBlob,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0,
      outputBlob,
    );

    if (result == 0) {
      _freeBlob(inputBlob);
      calloc.free(outputBlob);
      throw Exception('Windows encryption failed');
    }

    final encryptedBytes = outputBlob.ref.pbData.asTypedList(
      outputBlob.ref.cbData,
    );
    final base64 = base64Encode(encryptedBytes);

    LocalFree(outputBlob.ref.pbData);
    _freeBlob(inputBlob);
    calloc.free(outputBlob);
    return base64;
  }

  String _decryptWindows(String base64Str) {
    final encryptedBytes = base64Decode(base64Str);
    final inputBlob = _createBlob(encryptedBytes);
    final outputBlob = calloc<CRYPT_INTEGER_BLOB>();

    final result = CryptUnprotectData(
      inputBlob,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0,
      outputBlob,
    );

    if (result == 0) {
      _freeBlob(inputBlob);
      calloc.free(outputBlob);
      throw Exception('Windows decryption failed');
    }

    final decryptedBytes = outputBlob.ref.pbData.asTypedList(
      outputBlob.ref.cbData,
    );
    final plainText = utf8.decode(decryptedBytes);

    LocalFree(outputBlob.ref.pbData);
    _freeBlob(inputBlob);
    calloc.free(outputBlob);
    return plainText;
  }

  Pointer<CRYPT_INTEGER_BLOB> _createBlob(List<int> bytes) {
    final blob = calloc<CRYPT_INTEGER_BLOB>();
    final data = calloc<Uint8>(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      data[i] = bytes[i];
    }
    blob.ref.cbData = bytes.length;
    blob.ref.pbData = data;
    return blob;
  }

  void _freeBlob(Pointer<CRYPT_INTEGER_BLOB> blob) {
    calloc.free(blob.ref.pbData);
    calloc.free(blob);
  }
}
