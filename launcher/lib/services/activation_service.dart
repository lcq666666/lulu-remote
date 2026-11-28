import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'machine_code_service.dart';
import 'secure_store.dart';

enum ActivationError {
  unreachable('连不上激活服务器，请检查网络和组网，再重试。'),
  wrongKey('密钥不正确，请核对后重新输入。'),
  usedKey('该密钥已被使用，请找作者领新密钥。'),
  hardwareChanged('本机硬件有变化，请找作者重新领码。'),
  unavailableHardware('暂时无法读取足够的设备信息，请检查权限后重新检测。'),
  invalidServer('无法确认激活服务器身份，请核对服务器地址。'),
  configuration('当前安装包缺少有效的激活公钥，请联系作者。'),
  storage('无法保存本机激活状态，请重试。'),
  revoked('本设备已被作者停用');

  const ActivationError(this.message);
  final String message;
}

class ActivationFailure implements Exception {
  const ActivationFailure(this.error);
  final ActivationError error;
}

String? normalizeActivationKey(String input) {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  final key = input.trim().toUpperCase();
  if (!RegExp('^LULU(-[$alphabet]{4}){4}\$').hasMatch(key)) return null;
  final body = key.substring(5).replaceAll('-', '');
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    sum += alphabet.indexOf(body[i]) * (2 * i + 1);
  }
  return body[15] == alphabet[sum % alphabet.length] ? key : null;
}

class ActivationVerifier {
  ActivationVerifier(this.publicKey);
  final String publicKey;
  final _algorithm = Ed25519();

  bool get configured => _decode(publicKey)?.length == 32;

  static List<int>? _decode(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      return null;
    }
  }

  Future<bool> verify(List<int> message, String proof) async {
    final key = _decode(publicKey);
    final signature = _decode(proof);
    if (key == null || key.length != 32 || signature?.length != 64) {
      return false;
    }
    try {
      return await _algorithm.verify(message,
          signature: Signature(signature!,
              publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)));
    } on Exception {
      return false;
    }
  }

  Future<MachineFingerprint?> fingerprint(String token) async {
    final fields = token.split('.');
    if (fields.length != 2) return null;
    final payload = _decode(fields[0]);
    if (payload == null || !await verify(payload, fields[1])) return null;
    try {
      final data = jsonDecode(utf8.decode(payload));
      if (data is! Map ||
          data['v'] != 1 ||
          data['key_id'] is! int ||
          data['issued_at'] is! int) return null;
      final device = data['device'];
      if (device is! Map ||
          device['platform'] is! String ||
          device['parts'] is! List ||
          !(device['parts'] as List).every((p) => p is String)) {
        return null;
      }
      final fingerprint = MachineFingerprint(device['platform'] as String,
          (device['parts'] as List).cast<String>());
      return fingerprint.valid && fingerprint.hash == data['machine_hash']
          ? fingerprint
          : null;
    } on FormatException {
      return null;
    }
  }
}

class ActivationState {
  const ActivationState({this.machine, this.error, this.active = false});
  final MachineFingerprint? machine;
  final ActivationError? error;
  final bool active;
}

class ActivationService {
  ActivationService({
    SecureStore? store,
    Future<MachineFingerprint> Function()? readMachine,
    ActivationVerifier? verifier,
    DateTime Function()? clock,
  })  : _store = store ?? SecureStore(),
        _readMachine = readMachine ?? const MachineCodeService().read,
        _verifier = verifier ?? ActivationVerifier(_buildPublicKey),
        _clock = clock ?? DateTime.now;

  static const _buildPublicKey =
      String.fromEnvironment('LULU_ACTIVATION_PUBLIC_KEY');
  static const _buildServer = String.fromEnvironment('LULU_ACTIVATION_SERVER');
  static const buildRequiresActivation =
      bool.fromEnvironment('LULU_ACTIVATION_REQUIRED');
  static const _serverKey = 'lulu_activation_server';
  static const _validateKey = 'lulu_activation_last_check';
  static const _revokedKey = 'lulu_activation_revoked';
  static const _week = Duration(days: 7);
  static const _healthRetry = Duration(minutes: 5);
  final SecureStore _store;
  final Future<MachineFingerprint> Function() _readMachine;
  final ActivationVerifier _verifier;
  final DateTime Function() _clock;
  bool _checking = false;
  int? _lastHealthAttempt;

  Future<String> server() async =>
      (await SharedPreferences.getInstance()).getString(_serverKey) ??
      _buildServer;

  Future<ActivationState> load() async {
    if (!_verifier.configured) {
      return const ActivationState(error: ActivationError.configuration);
    }
    MachineFingerprint machine;
    try {
      machine = await _readMachine();
      if (!machine.valid) {
        return const ActivationState(
            error: ActivationError.unavailableHardware);
      }
    } catch (_) {
      return const ActivationState(error: ActivationError.unavailableHardware);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_revokedKey) == true) {
        return ActivationState(
            machine: machine, error: ActivationError.revoked);
      }
      final token = await _store.readActivationToken();
      if (token == null) return ActivationState(machine: machine);
      final bound = await _verifier.fingerprint(token);
      if (bound == null) return ActivationState(machine: machine);
      if (!bound.matches(machine)) {
        return ActivationState(
            machine: machine, error: ActivationError.hardwareChanged);
      }
      return ActivationState(machine: machine, active: true);
    } catch (_) {
      return ActivationState(machine: machine, error: ActivationError.storage);
    }
  }

  Future<ActivationState> activate(
      String input, String address, MachineFingerprint machine) async {
    final key = normalizeActivationKey(input);
    if (key == null) throw const ActivationFailure(ActivationError.wrongKey);
    if (!machine.valid) {
      throw const ActivationFailure(ActivationError.unavailableHardware);
    }
    if (!_verifier.configured) {
      throw const ActivationFailure(ActivationError.configuration);
    }
    final endpoint = _address(address);
    await _verifyServer(endpoint);
    final response = await _request(endpoint, '/v1/activate', body: {
      'key': key,
      'machine_code': machine.code,
      ...machine.toJson(),
    });
    switch (response.code) {
      case 404:
        throw const ActivationFailure(ActivationError.wrongKey);
      case 409:
        throw const ActivationFailure(ActivationError.usedKey);
      case 403:
        throw const ActivationFailure(ActivationError.revoked);
      case 400:
        throw const ActivationFailure(ActivationError.hardwareChanged);
      case 200:
        break;
      default:
        throw const ActivationFailure(ActivationError.unreachable);
    }
    final token = response.data['token'];
    final bound = token is String ? await _verifier.fingerprint(token) : null;
    if (token is! String || bound?.hash != machine.hash) {
      throw const ActivationFailure(ActivationError.invalidServer);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_serverKey, endpoint.toString()) ||
          !await prefs.setInt(_validateKey, _clock().millisecondsSinceEpoch) ||
          !await prefs.remove(_revokedKey)) {
        throw const ActivationFailure(ActivationError.storage);
      }
      await _store.writeActivationToken(token);
      if (await _store.readActivationToken() != token) {
        throw const ActivationFailure(ActivationError.storage);
      }
    } catch (_) {
      throw const ActivationFailure(ActivationError.storage);
    }
    return ActivationState(machine: machine, active: true);
  }

  Future<void> reset() => _store.deleteActivationToken();

  Future<bool> checkRevocation() async {
    if (_checking) return false;
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = _clock().millisecondsSinceEpoch;
      final previous = prefs.getInt(_validateKey);
      if (previous != null && now - previous < _week.inMilliseconds) {
        return false;
      }
      final token = await _store.readActivationToken();
      if (token == null) return false;
      final endpoint = _address(await server());
      final lastHealth = _lastHealthAttempt;
      if (lastHealth != null &&
          now >= lastHealth &&
          now - lastHealth < _healthRetry.inMilliseconds) return false;
      // Confirm the configured server is reachable and holds the signing key
      // before using this week's validation attempt. Failed readiness checks
      // are retried independently of the weekly /v1/validate limit.
      _lastHealthAttempt = now;
      await _verifyServer(endpoint);
      _lastHealthAttempt = null;
      if (await _store.readActivationToken() != token) return false;
      // After sending validate we may lose its response. Count the attempt
      // once it can be sent, so foreground events do not send it again.
      if (!await prefs.setInt(_validateKey, _clock().millisecondsSinceEpoch)) {
        return false;
      }
      final nonce = _nonce();
      final result = await _request(endpoint, '/v1/validate',
          body: {'token': token, 'nonce': nonce});
      final proof = result.data['proof'];
      if (result.code != 200 ||
          result.data['revoked'] != true ||
          result.data['valid'] != false ||
          proof is! String ||
          !await _verifier.verify(
              utf8.encode('lulu-revoked-v1:$nonce:${activationDigest(token)}'),
              proof) ||
          await _store.readActivationToken() != token) return false;
      var persisted = false;
      try {
        persisted = await prefs.setBool(_revokedKey, true);
      } catch (_) {
        // An authenticated revocation still removes the credential.
      }
      try {
        await _store.deleteActivationToken();
      } catch (_) {
        if (!persisted) return false;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _checking = false;
    }
  }

  Future<void> _verifyServer(Uri endpoint) async {
    final nonce = _nonce();
    final status =
        await _request(endpoint, '/v1/status', query: {'nonce': nonce});
    if (status.code != 200 || status.data['ok'] != true) {
      throw const ActivationFailure(ActivationError.unreachable);
    }
    final proof = status.data['proof'];
    if (proof is! String ||
        !await _verifier.verify(utf8.encode('lulu-status-v1:$nonce'), proof)) {
      throw const ActivationFailure(ActivationError.invalidServer);
    }
  }

  static String _nonce() {
    final random = Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Uri _address(String value) {
    final trimmed = value.trim();
    final endpoint =
        Uri.tryParse(trimmed.contains('://') ? trimmed : 'http://$trimmed');
    if (endpoint == null ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw const ActivationFailure(ActivationError.unreachable);
    }
    final ip = InternetAddress.tryParse(endpoint.host);
    final bytes = ip?.rawAddress;
    if (bytes == null ||
        bytes.length != 4 ||
        endpoint.port < 1 ||
        endpoint.port > 65535 ||
        !(ip!.address == '127.0.0.1' ||
            bytes[0] == 10 ||
            bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128)) {
      throw const ActivationFailure(ActivationError.unreachable);
    }
    return endpoint;
  }

  Future<({int code, Map<String, dynamic> data})> _request(
      Uri endpoint, String path,
      {Map<String, String>? query, Map<String, Object>? body}) async {
    const timeout = Duration(seconds: 5);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.openUrl(body == null ? 'GET' : 'POST',
            endpoint.replace(path: path, queryParameters: query));
        request.followRedirects = false;
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final data = <int>[];
        await for (final bytes in response) {
          if (data.length + bytes.length > 4096) throw const FormatException();
          data.addAll(bytes);
        }
        if (response.statusCode != 200) {
          return (code: response.statusCode, data: <String, dynamic>{});
        }
        final value = jsonDecode(utf8.decode(data));
        if (value is! Map<String, dynamic>) throw const FormatException();
        return (code: response.statusCode, data: value);
      })()
          .timeout(timeout);
    } catch (_) {
      throw const ActivationFailure(ActivationError.unreachable);
    } finally {
      client.close(force: true);
    }
  }
}
