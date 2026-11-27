import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

const fileTransferPort = 47995;
const fileTransferMaxBytes = 2 * 1024 * 1024 * 1024;
const _idleTimeout = Duration(seconds: 20);
const _headersTimeout = Duration(seconds: 5);
const _challengePath = '/v1/files/challenge';
const _uploadPath = '/v1/files/upload';
final _noncePattern = RegExp(r'^[a-f0-9]{32}$');
final _signaturePattern = RegExp(r'^[a-f0-9]{64}$');

String newTransferCode() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

bool validTransferCode(String code) {
  if (!RegExp(r'^[\w-]{43}$').hasMatch(code)) return false;
  final bytes = base64Url.decode('$code=');
  return base64Url.encode(bytes) == '$code=';
}

String _nonce() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String _sign(String code, List<Object> parts) =>
    Hmac(sha256, base64Url.decode('$code='))
        .convert(utf8.encode(jsonEncode(['qg-file-transfer-v1', ...parts])))
        .toString();

bool _matches(String received, String expected) {
  if (received.length != expected.length) return false;
  var different = 0;
  for (var i = 0; i < expected.length; i++) {
    different |= received.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return different == 0;
}

bool safeTransferName(String name) {
  if (name.isEmpty ||
      utf8.encode(name).length > 200 ||
      name.startsWith('.') ||
      name.endsWith('.') ||
      name.trim() != name ||
      RegExp(r'[/\\:*?"<>|\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]')
          .hasMatch(name)) {
    return false;
  }
  final stem = name.split('.').first.trimRight().toUpperCase();
  return !RegExp(
          r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9¹²³]|LPT[0-9¹²³])$')
      .hasMatch(stem);
}

class FileTransferFailure implements Exception {
  const FileTransferFailure(this.message);
  final String message;
}

class FileTransferServer {
  FileTransferServer({required this.code, required this.receiveDirectory}) {
    if (!validTransferCode(code)) throw ArgumentError('Invalid transfer code');
  }

  final String code;
  final Directory receiveDirectory;
  final _challenges = <String, DateTime>{};
  bool enabled = true;
  bool _receiving = false;

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.contentType = ContentType.json;
    response.persistentConnection = false;
    try {
      if (!enabled) {
        response.statusCode = HttpStatus.forbidden;
      } else if (request.method == 'GET' &&
          request.uri.path == _challengePath) {
        _issueChallenge(request);
      } else if (request.method == 'POST' && request.uri.path == _uploadPath) {
        await _receive(request);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
    } on TimeoutException {
      response.statusCode = HttpStatus.requestTimeout;
    } on IOException {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await response.close();
      } on IOException {
        // The sender may close the connection to cancel a transfer.
      }
    }
  }

  void _issueChallenge(HttpRequest request) {
    final response = request.response;
    final client = request.headers.value('x-qg-client') ?? '';
    final proof = request.headers.value('x-qg-proof') ?? '';
    if (!_noncePattern.hasMatch(client) ||
        !_matches(proof, _sign(code, ['hello', client]))) {
      response.statusCode = HttpStatus.unauthorized;
      return;
    }
    final now = DateTime.now();
    _challenges.removeWhere((_, expiry) => !now.isBefore(expiry));
    if (_challenges.length >= 64 || _receiving) {
      response.statusCode = HttpStatus.tooManyRequests;
      return;
    }
    final challenge = _nonce();
    _challenges[challenge] = now.add(const Duration(minutes: 1));
    response.write(jsonEncode({
      'challenge': challenge,
      'proof': _sign(code, ['server', client, challenge]),
    }));
  }

  Future<void> _receive(HttpRequest request) async {
    final response = request.response;
    final challenge = request.headers.value('x-qg-challenge') ?? '';
    final name = utf8.decode(base64Url
        .decode(base64Url.normalize(request.headers.value('x-qg-name') ?? '')));
    final digest = request.headers.value('x-qg-sha256') ?? '';
    final proof = request.headers.value('x-qg-proof') ?? '';
    final size = request.contentLength;
    if (!safeTransferName(name) ||
        !_signaturePattern.hasMatch(digest) ||
        size < 0) {
      response.statusCode = HttpStatus.badRequest;
      return;
    }
    if (size > fileTransferMaxBytes) {
      response.statusCode = HttpStatus.requestEntityTooLarge;
      return;
    }
    final expires = _challenges[challenge];
    if (expires == null ||
        !DateTime.now().isBefore(expires) ||
        !_matches(
            proof, _sign(code, ['upload', challenge, name, size, digest]))) {
      response.statusCode = HttpStatus.unauthorized;
      return;
    }
    _challenges.remove(challenge);
    if (_receiving) {
      response.statusCode = HttpStatus.tooManyRequests;
      return;
    }
    _receiving = true;
    Directory? staging;
    File? partial;
    RandomAccessFile? output;
    try {
      await receiveDirectory.create(recursive: true);
      staging = await receiveDirectory.createTemp('.qg-');
      partial = File('${staging.path}${Platform.pathSeparator}upload');
      final opened = await partial.open(mode: FileMode.writeOnly);
      output = opened;
      final checksum = _DigestSink();
      final sink = sha256.startChunkedConversion(checksum);
      var received = 0;
      await for (final chunk in request.timeout(_idleTimeout)) {
        received += chunk.length;
        if (!enabled) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        if (received > size) throw const FormatException();
        sink.add(chunk);
        await opened.writeFrom(chunk);
      }
      sink.close();
      await opened.close();
      output = null;
      if (!enabled) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (received != size || checksum.value?.toString() != digest) {
        response.statusCode = HttpStatus.unprocessableEntity;
        return;
      }
      final path = '${receiveDirectory.path}${Platform.pathSeparator}';
      var savedName = name;
      if (await FileSystemEntity.type('$path$name', followLinks: false) !=
          FileSystemEntityType.notFound) {
        savedName = '${_nonce().substring(0, 10)}-$name';
      }
      if (!enabled) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      await partial.rename('$path$savedName');
      partial = null;
      response.statusCode = HttpStatus.created;
      response.write(jsonEncode({
        'name': savedName,
        'proof': _sign(code, ['receipt', challenge, savedName, digest]),
      }));
    } finally {
      _receiving = false;
      try {
        await output?.close();
        if (partial != null && await partial.exists()) await partial.delete();
        await staging?.delete();
      } on FileSystemException {
        // An interrupted upload is left only in its private staging directory.
      }
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class FileTransferClient {
  FileTransferClient({this.bytesPerSecond = 4 * 1024 * 1024});
  final int bytesPerSecond;
  HttpClient? _current;

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _current?.close(force: true);
  }

  Stream<List<int>> _read(Stream<List<int>> Function() openRead) async* {
    await for (final chunk in openRead().timeout(_idleTimeout)) {
      if (_cancelled) throw const FileTransferFailure('已取消。');
      yield chunk;
    }
  }

  Future<String> send({
    required Uri endpoint,
    required String code,
    required String name,
    required int length,
    required Stream<List<int>> Function() openRead,
    required void Function(int sent, double bytesPerSecond) onProgress,
  }) async {
    if (!validTransferCode(code)) throw const FileTransferFailure('请核对接收码。');
    if (!safeTransferName(name)) {
      throw const FileTransferFailure('文件名包含不支持的字符。');
    }
    if (length < 0 || length > fileTransferMaxBytes) {
      throw const FileTransferFailure('单个文件不能超过 2 GB。');
    }
    if (_current != null) throw const FileTransferFailure('另一个文件正在发送。');
    final client = HttpClient()
      ..connectionTimeout = _headersTimeout
      ..findProxy = (_) => 'DIRECT';
    _current = client;
    _cancelled = false;
    try {
      final digest = (await sha256.bind(_read(openRead)).first).toString();
      final clientNonce = _nonce();
      final handshake = await _readJson(
          await _requestChallenge(client, endpoint, code, clientNonce),
          HttpStatus.ok);
      final challenge = handshake['challenge'];
      if (challenge is! String ||
          !_noncePattern.hasMatch(challenge) ||
          !_matches(handshake['proof'] as String? ?? '',
              _sign(code, ['server', clientNonce, challenge]))) {
        throw const FileTransferFailure('无法验证接收电脑。');
      }
      final request = await client.postUrl(endpoint.replace(path: _uploadPath));
      request.followRedirects = false;
      request.contentLength = length;
      request.headers.contentType = ContentType.binary;
      request.headers.set('x-qg-challenge', challenge);
      request.headers.set(
          'x-qg-name', base64Url.encode(utf8.encode(name)).replaceAll('=', ''));
      request.headers.set('x-qg-sha256', digest);
      request.headers.set('x-qg-proof',
          _sign(code, ['upload', challenge, name, length, digest]));
      final stopwatch = Stopwatch()..start();
      var sent = 0;
      var nextProgress = 0;
      final chunks = _read(openRead).asyncMap((chunk) async {
        sent += chunk.length;
        if (bytesPerSecond > 0) {
          final delay =
              sent * 1000000 ~/ bytesPerSecond - stopwatch.elapsedMicroseconds;
          if (delay > 0) {
            await Future<void>.delayed(Duration(microseconds: delay));
          }
        }
        final elapsed = stopwatch.elapsedMilliseconds;
        if (elapsed >= nextProgress || sent == length) {
          onProgress(sent, elapsed == 0 ? 0 : sent * 1000 / elapsed);
          nextProgress = elapsed + 200;
        }
        return chunk;
      });
      final HttpClientResponse response;
      try {
        await request.addStream(chunks);
        response = await request.close().timeout(_idleTimeout);
      } on IOException {
        // An early rejection can close the socket before upload completes.
        await _checkInterruptedReceiver(client, endpoint, code);
        rethrow;
      }
      final receipt = await _readJson(response, HttpStatus.created);
      final savedName = receipt['name'];
      if (savedName is! String ||
          !_matches(receipt['proof'] as String? ?? '',
              _sign(code, ['receipt', challenge, savedName, digest]))) {
        throw const FileTransferFailure('未收到接收电脑的确认。');
      }
      return savedName;
    } on FileTransferFailure {
      rethrow;
    } on Exception {
      throw const FileTransferFailure('文件传输未完成。请检查组网和对方的接收文件设置。');
    } finally {
      client.close(force: true);
      _current = null;
    }
  }

  Future<HttpClientResponse> _requestChallenge(
      HttpClient client, Uri endpoint, String code, String nonce) async {
    try {
      final request =
          await client.getUrl(endpoint.replace(path: _challengePath));
      request.followRedirects = false;
      request.headers.set('x-qg-client', nonce);
      request.headers.set('x-qg-proof', _sign(code, ['hello', nonce]));
      return await request.close().timeout(_headersTimeout);
    } on SocketException {
      if (_cancelled) throw const FileTransferFailure('已取消。');
      throw const FileTransferFailure('无法连接文件接收服务。请确认对方已开启「文件接收」，且两台设备都在线。');
    }
  }

  Future<void> _checkInterruptedReceiver(
      HttpClient client, Uri endpoint, String code) async {
    if (_cancelled) return;
    try {
      final response =
          await _requestChallenge(client, endpoint, code, _nonce());
      if (response.statusCode == HttpStatus.forbidden) {
        throw const FileTransferFailure('对方电脑已关闭文件接收。');
      }
    } on IOException {
      // Preserve the original upload failure when no status is available.
    } on TimeoutException {
      // Preserve the original upload failure when no status is available.
    }
  }

  Future<Map<String, dynamic>> _readJson(
      HttpClientResponse response, int expected) async {
    if (response.statusCode != expected) {
      throw FileTransferFailure(switch (response.statusCode) {
        HttpStatus.forbidden => '对方电脑已关闭文件接收。',
        HttpStatus.unauthorized => '接收码不正确或已更换。',
        HttpStatus.tooManyRequests => '对方电脑正在接收文件，请稍后重试。',
        HttpStatus.unprocessableEntity => '文件校验失败，请重新选择文件。',
        _ => '接收电脑未能保存文件（${response.statusCode}）。',
      });
    }
    final body = <int>[];
    await for (final chunk in response.timeout(_headersTimeout)) {
      if (body.length + chunk.length > 2048) throw const FormatException();
      body.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    return decoded;
  }
}
