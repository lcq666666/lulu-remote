import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The only place secrets live.
///
/// - Windows: DPAPI-backed credential store (via flutter_secure_storage).
/// - Android: encrypted settings protected by the Android Keystore.
///
/// Nothing here is ever written to SharedPreferences, a JSON file, or a
/// log. Callers pass a device id so per-host secrets stay separate.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _key(String name, [String? deviceId]) =>
      deviceId == null ? 'lulu_$name' : 'lulu_${deviceId}_$name';

  Future<String?> readActivationToken() =>
      _storage.read(key: _key('activation_token'));
  Future<void> writeActivationToken(String token) =>
      _storage.write(key: _key('activation_token'), value: token);
  Future<void> deleteActivationToken() =>
      _storage.delete(key: _key('activation_token'));

  // --- LULU client identity (one identity for this launcher install) ---
  Future<String?> readClientCertPem() => _storage.read(key: _key('client_cert_pem'));
  Future<void> writeClientCertPem(String pem) =>
      _storage.write(key: _key('client_cert_pem'), value: pem);
  Future<String?> readClientKeyPem() => _storage.read(key: _key('client_key_pem'));
  Future<void> writeClientKeyPem(String pem) =>
      _storage.write(key: _key('client_key_pem'), value: pem);
  // RSA private-key components as JSON (n/e/d/p/q, hex) — used by the
  // pairing module for signing. The PKCS#8 PEM above is the same key in
  // the form dart:io SecurityContext needs for mutual TLS. Both live
  // only in secure storage; they are two encodings of one key.
  Future<String?> readClientKeyJson() => _storage.read(key: _key('client_key_json'));
  Future<void> writeClientKeyJson(String json) =>
      _storage.write(key: _key('client_key_json'), value: json);
  Future<String?> readUniqueId() => _storage.read(key: _key('uniqueid'));
  Future<void> writeUniqueId(String value) =>
      _storage.write(key: _key('uniqueid'), value: value);

  // --- Per-host pinned server certificate (DER, hex) ---
  Future<String?> readServerCertHex(String deviceId) =>
      _storage.read(key: _key('server_cert_hex', deviceId));
  Future<void> writeServerCertHex(String deviceId, String hex) =>
      _storage.write(key: _key('server_cert_hex', deviceId), value: hex);

  // --- Sunshine admin credentials, entered once per host ---
  Future<String?> readSunshineUser(String deviceId) =>
      _storage.read(key: _key('sunshine_user', deviceId));
  Future<void> writeSunshineUser(String deviceId, String user) =>
      _storage.write(key: _key('sunshine_user', deviceId), value: user);
  Future<String?> readSunshinePassword(String deviceId) =>
      _storage.read(key: _key('sunshine_password', deviceId));
  Future<void> writeSunshinePassword(String deviceId, String password) =>
      _storage.write(key: _key('sunshine_password', deviceId), value: password);

  Future<void> deleteDeviceSecrets(String deviceId) async {
    for (final name in ['server_cert_hex', 'sunshine_user', 'sunshine_password']) {
      await _storage.delete(key: _key(name, deviceId));
    }
  }
}
