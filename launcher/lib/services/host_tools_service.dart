import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'file_transfer_service.dart';
import 'host_hardware.dart';

const _path = '/v1/host-tools/';
const _timeout = Duration(seconds: 8);
const _challengeLife = Duration(seconds: 30);
const clipboardMaxBytes = 64 * 1024;
const _maxBodyBytes = clipboardMaxBytes + 28;
final _cipher = AesGcm.with256bits();

class HostToolsException implements Exception {
  const HostToolsException(this.message);
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
    utf8.encode('qg-host-tools-v1/$phase/$binding');

Future<List<int>> _seal(
    String code, String phase, String binding, List<int> bytes) async {
  final box = await _cipher.encrypt(bytes,
      secretKey: SecretKey(base64Url.decode('$code=')),
      aad: _aad(phase, binding));
  return box.concatenation();
}

Future<List<int>> _open(
    String code, String phase, String binding, List<int> bytes) {
  if (bytes.length < 28) throw const FormatException();
  return _cipher.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
      secretKey: SecretKey(base64Url.decode('$code=')),
      aad: _aad(phase, binding));
}

class HostToolsServer {
  HostToolsServer(
      {required this.code,
      required this.readClipboard,
      required this.writeClipboard,
      this.readDiagnostics,
      this.readHardware});

  final String code;
  final Future<String> Function() readClipboard;
  final Future<void> Function(String) writeClipboard;
  final Future<String> Function()? readDiagnostics;
  final Future<HostHardware> Function()? readHardware;
  bool clipboardEnabled = false;
  bool hardwareEnabled = false;
  bool diagnosticsEnabled = false;
  bool active = true;
  final _issued = <String, Duration>{};
  final _usedHellos = <String, Duration>{};
  final _clock = Stopwatch()..start();
  int _pending = 0;

  bool _allows(String operation) =>
      active &&
      switch (operation) {
        'challenge' =>
          clipboardEnabled || diagnosticsEnabled || hardwareEnabled,
        'clipboard-read' || 'clipboard-write' => clipboardEnabled,
        'diagnostics' => diagnosticsEnabled && readDiagnostics != null,
        'hardware' => hardwareEnabled && readHardware != null,
        _ => false,
      };

  static bool handles(String path) => path.startsWith(_path);

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.contentType = ContentType.binary;
    var counted = false;
    try {
      final operation = request.uri.path.substring(_path.length);
      if (!_allows(operation)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final id = request.headers.value('x-qg-request') ?? '';
      if (request.method != 'POST' ||
          !validTransferCode(id) ||
          !const {
            'challenge',
            'clipboard-read',
            'clipboard-write',
            'diagnostics',
            'hardware'
          }.contains(operation)) {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      final limit = operation == 'clipboard-write' ? _maxBodyBytes : 28;
      if (request.contentLength < 28 || request.contentLength > limit) {
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
      if (!_allows(operation)) {
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
        if (operation == 'hardware') {
          result = utf8.encode(
              jsonEncode((await readHardware!().timeout(_timeout)).toJson()));
        } else if (operation == 'diagnostics') {
          result = utf8.encode(await readDiagnostics!().timeout(_timeout));
        } else if (operation == 'clipboard-read') {
          result = utf8.encode(await readClipboard().timeout(_timeout));
          if (result.isEmpty || result.length > clipboardMaxBytes) {
            response.statusCode = HttpStatus.unprocessableEntity;
            return;
          }
        } else {
          if (plaintext.isEmpty) throw const FormatException();
          await writeClipboard(utf8.decode(plaintext)).timeout(_timeout);
          result = const [];
        }
      }
      final sealed = await _seal(code, 'response', binding, result);
      if (!_allows(operation)) {
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

class HostToolsClient {
  HostToolsClient(this.address, this.code, {this.port = fileTransferPort});

  final String address;
  final String code;
  final int port;

  Future<String> readClipboard() async =>
      utf8.decode(await _exchange('clipboard-read', const []));

  Future<String> diagnostics() async =>
      utf8.decode(await _exchange('diagnostics', const []));

  Future<HostHardware> hardware() async => HostHardware.fromJson(
      jsonDecode(utf8.decode(await _exchange('hardware', const [])))
          as Map<String, dynamic>);

  Future<void> writeClipboard(String text) async {
    final bytes = utf8.encode(text);
    if (bytes.isEmpty || bytes.length > clipboardMaxBytes) {
      throw const HostToolsException('剪贴板需要有文本，最多支持 64 KiB。');
    }
    await _exchange('clipboard-write', bytes);
  }

  Future<List<int>> _exchange(String operation, List<int> payload) async {
    if (!validTransferCode(code)) {
      throw const HostToolsException('请填写正确的协作码。');
    }
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final hello =
          await _post(client, 'challenge', newTransferCode(), const []);
      final challenge = utf8.decode(hello);
      if (!validTransferCode(challenge)) throw const FormatException();
      return await _post(client, operation, challenge, payload);
    } on HostToolsException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw const HostToolsException('无法验证被控电脑的回应。请重新确认协作码。');
    } on Exception {
      throw const HostToolsException('无法连接被控电脑。请检查组网和被控端开关。');
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
      throw HostToolsException(switch (response.statusCode) {
        HttpStatus.forbidden => '被控电脑未开启这项功能。',
        HttpStatus.unauthorized => '协作码不正确，或请求已过期。',
        HttpStatus.unprocessableEntity => '被控端剪贴板没有可发送的文本，或文本超过 64 KiB。',
        HttpStatus.tooManyRequests => '被控电脑繁忙，请稍后再试。',
        _ => '被控电脑暂时无法完成操作。',
      });
    }
    if (response.contentLength < 28 || response.contentLength > _maxBodyBytes) {
      throw const FormatException();
    }
    return _open(code, 'response', binding,
        await _read(response, _maxBodyBytes).timeout(_timeout));
  }
}
