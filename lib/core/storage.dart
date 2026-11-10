import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

final vaultProvider = Provider((ref) => const CredentialVault());
final preferencesProvider = Provider<SharedPreferences>((ref) {
  throw StateError('Preferences must be initialized before starting HomeHub.');
});

class CredentialVault {
  const CredentialVault({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  });

  final FlutterSecureStorage storage;

  Future<List<Map<String, dynamic>>> readList(String key) async {
    final value = await storage.read(key: key);
    if (value == null) return [];
    return (jsonDecode(value) as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<void> writeList(String key, List<Map<String, dynamic>> value) =>
      storage.write(key: key, value: jsonEncode(value));
}
