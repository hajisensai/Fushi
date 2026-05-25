import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SyncTokenStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyAccessToken = 'sync_access_token';
  static const _keyRefreshToken = 'sync_refresh_token';
  static const _keyClientId = 'sync_client_id';

  static Future<void> saveAccessToken(String token) =>
      _storage.write(key: _keyAccessToken, value: token);

  static Future<void> saveRefreshToken(String token) =>
      _storage.write(key: _keyRefreshToken, value: token);

  static Future<void> saveClientId(String clientId) =>
      _storage.write(key: _keyClientId, value: clientId);

  static Future<String?> getAccessToken() =>
      _storage.read(key: _keyAccessToken);

  static Future<String?> getRefreshToken() =>
      _storage.read(key: _keyRefreshToken);

  static Future<String?> getClientId() => _storage.read(key: _keyClientId);

  static Future<bool> get isAuthenticated async {
    final access = await getAccessToken();
    final refresh = await getRefreshToken();
    final client = await getClientId();
    return access != null && refresh != null && client != null;
  }

  static Future<void> clear() async {
    await _storage.delete(key: _keyAccessToken);
    await _storage.delete(key: _keyRefreshToken);
    await _storage.delete(key: _keyClientId);
  }
}
