import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'file_transfer_service.dart';
import 'wake_on_lan.dart';

const _path = '/v1/wake-relay/';
const _timeout = Duration(seconds: 8);
const _challengeLife = Duration(seconds: 30);
const _boxOverhead = 28;
const _codeBytes = 43;
const _macBytes = 17;
final _cipher = AesGcm.with256bits();

class WakeRelayException implements Exception {
  const WakeRelayException(this.message);
  final String message;
}

Future<List<int>> _read(Stream<List<int>> stream, int size) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(_timeout)) {
    if (chunk.length > size - bytes.length) throw const FormatException();
    bytes.addAll(chunk);
  }
  return bytes;
}

List<int> _aad(String phase, String binding) =>
    utf8.encode('qg-wake-relay-v1/$phase/$binding');

Future<List<int>> _seal(
    String code, String phase, String binding, List<int> bytes) async {
  final box = await _cipher.encrypt(bytes,
      secretKey: SecretKey(base64Url.decode('$code=')),
      aad: _aad(phase, binding));
  return box.concatenation();
}

Future<List<int>> _open(
    String code, String phase, String binding, List<int> bytes) {
  if (bytes.length < _boxOverhead) throw const FormatException();
  return _cipher.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
      secretKey: SecretKey(base64Url.decode('$code=')),
      aad: _aad(phase, binding));
}

class WakeRelayServer {
  WakeRelayServer({required this.code, required this.sendWake});

  final String code;
  final Future<void> Function(String) sendWake;
  Set<String> wakeTargets = const {};
  bool active = true;
  final _issued = <String, Duration>{};
  final _usedHellos = <String, Duration>{};
  final _clock = Stopwatch()..start();
  int _pending = 0;

  bool get _allows => active && wakeTargets.isNotEmpty;

  static bool handles(String path) => path.startsWith(_path);

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.contentType = ContentType.binary;
    var counted = false;
    try {
      final operation = request.uri.path.substring(_path.length);
      if (!_allows) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final id = request.headers.value('x-qg-request') ?? '';
      if (request.method != 'POST' ||
          !validTransferCode(id) ||
          (operation != 'challenge' && operation != 'wake')) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      final limit = _boxOverhead + (operation == 'wake' ? _macBytes : 0);
      if (request.contentLength != limit) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      if (_pending >= 8) {
        response.statusCode = HttpStatus.tooManyRequests;
        return;
      }
      _pending++;
      counted = true;
      final binding = '$operation/$id';
      final plaintext = await _open(code, 'request', binding,
          await _read(request, limit).timeout(_timeout));
      if (!_allows) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final now = _clock.elapsed;
      _issued.removeWhere((_, expiry) => expiry <= now);
      _usedHellos.removeWhere((_, expiry) => expiry <= now);
      final List<int> result;
      if (operation == 'challenge') {
        if (_usedHellos.containsKey(id) ||
            _usedHellos.length >= 64 ||
            _issued.length >= 32) {
          response.statusCode = HttpStatus.tooManyRequests;
          return;
        }
        final challenge = newTransferCode();
        _usedHellos[id] = now + _challengeLife;
        _issued[challenge] = now + _challengeLife;
        result = utf8.encode(challenge);
      } else {
        if (_issued.remove(id) == null) {
          response.statusCode = HttpStatus.unauthorized;
          return;
        }
        final mac = WakeOnLan.normalizeMac(utf8.decode(plaintext));
        if (mac == null) throw const FormatException();
        if (!wakeTargets.contains(mac)) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        await sendWake(mac).timeout(_timeout);
        result = const [];
      }
      final sealed = await _seal(code, 'response', binding, result);
      if (!_allows) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      response.contentLength = sealed.length;
      response.add(sealed);
    } on SecretBoxAuthenticationError {
      response.statusCode = HttpStatus.unauthorized;
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
    } catch (_) {
      response.statusCode = HttpStatus.serviceUnavailable;
    } finally {
      if (counted) _pending--;
      try {
        await response.close();
      } on Exception {
        // Client left before receiving the response.
      }
    }
  }
}

class WakeRelayClient {
  WakeRelayClient(this.address, this.code, {this.port = fileTransferPort});

  final String address;
  final String code;
  final int port;

  Future<void> wake(String mac) async {
    final normalized = WakeOnLan.normalizeMac(mac);
    if (normalized == null) throw const FormatException();
    await _exchange(utf8.encode(normalized));
  }

  Future<void> _exchange(List<int> payload) async {
    if (!validTransferCode(code)) {
      throw const WakeRelayException('请填写正确的唤醒转发码。');
    }
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final hello =
          await _post(client, 'challenge', newTransferCode(), const []);
      final challenge = utf8.decode(hello);
      if (!validTransferCode(challenge)) throw const FormatException();
      await _post(client, 'wake', challenge, payload);
    } on WakeRelayException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw const WakeRelayException('无法验证转发电脑的回应。请重新确认唤醒转发码。');
    } on Exception {
      throw const WakeRelayException('无法连接转发电脑。请检查组网和转发开关。');
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _post(
      HttpClient client, String operation, String id, List<int> payload) async {
    final binding = '$operation/$id';
    final sealed = await _seal(code, 'request', binding, payload);
    final request = await client
        .postUrl(Uri(
            scheme: 'http',
            host: address,
            port: port,
            path: '$_path$operation'))
        .timeout(_timeout);
    request.followRedirects = false;
    request.headers.set('x-qg-request', id);
    request.headers.contentType = ContentType.binary;
    request.contentLength = sealed.length;
    request.add(sealed);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw WakeRelayException(switch (response.statusCode) {
        HttpStatus.forbidden => '转发电脑未开启唤醒转发，或尚未登记这台电脑的有线网卡 MAC。',
        HttpStatus.unauthorized => '唤醒转发码不正确，或请求已过期。',
        HttpStatus.tooManyRequests => '转发电脑繁忙，请稍后再试。',
        _ => '转发电脑暂时无法完成操作。',
      });
    }
    final limit = _boxOverhead + (operation == 'challenge' ? _codeBytes : 0);
    if (response.contentLength != limit) {
      throw const FormatException();
    }
    return _open(code, 'response', binding,
        await _read(response, limit).timeout(_timeout));
  }
}
