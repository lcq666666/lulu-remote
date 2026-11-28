import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_transfer_service.dart';
import 'secure_store.dart';

enum PowerAction { restart, shutdown, signOut }

extension PowerActionLabel on PowerAction {
  String get label => switch (this) {
        PowerAction.restart => '重启',
        PowerAction.shutdown => '关机',
        PowerAction.signOut => '注销',
      };

  List<String> get windowsArguments => switch (this) {
        PowerAction.restart => const ['/r', '/t', '0'],
        PowerAction.shutdown => const ['/s', '/t', '0'],
        PowerAction.signOut => const ['/l'],
      };
}

const _challengePath = '/v1/power/challenge';
const _actionPath = '/v1/power/action';
final _nonce = RegExp(r'^[A-Za-z0-9_-]{43}$');
const _timeout = Duration(seconds: 5);

String _proof(String key, List<String> fields) =>
    Hmac(sha256, base64Url.decode('$key='))
        .convert(utf8.encode(jsonEncode(['qg-power-v1', ...fields])))
        .toString();

bool _matches(String? value, String wanted) {
  if (value == null || value.length != wanted.length) return false;
  var different = 0;
  for (var i = 0; i < wanted.length; i++) {
    different |= value.codeUnitAt(i) ^ wanted.codeUnitAt(i);
  }
  return different == 0;
}

class PowerAccess {
  PowerAccess._();
  static final instance = PowerAccess._();
  final _store = SecureStore();
  static const _enabled = 'qg_power_enabled';
  Future<String>? _initializing;

  Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabled) ?? false;

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_enabled, value)) {
      await prefs.reload();
      throw StateError('无法保存远程电源设置。');
    }
  }

  Future<String> code() =>
      _initializing ??= _load().whenComplete(() => _initializing = null);

  Future<String> _load() async {
    final code = await _store.readHostPowerCode();
    if (code != null && validTransferCode(code)) return code;
    return _writeCode();
  }

  Future<String> rotate() async {
    if (_initializing case final work?) await work;
    return _writeCode();
  }

  Future<String> _writeCode() async {
    final newCode = newTransferCode();
    await _store.writeHostPowerCode(newCode);
    return newCode;
  }
}

class PowerServer {
  PowerServer({required this.code, required this.run});
  final String code;
  final Future<bool> Function(PowerAction) run;
  bool enabled = true;
  bool _executing = false;
  final _challenges = <String, DateTime>{};

  static bool handles(String path) =>
      path == _challengePath || path == _actionPath;

  Future<void> handle(HttpRequest request) async {
    final reply = request.response;
    reply.persistentConnection = false;
    reply.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    reply.headers.contentType = ContentType.json;
    try {
      if (!enabled) {
        reply.statusCode = HttpStatus.forbidden;
        return;
      }
      final token = request.headers.value('x-qg-power-nonce') ?? '';
      final proof = request.headers.value('x-qg-power-proof');
      if (!_nonce.hasMatch(token)) {
        reply.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.method == 'GET' && request.uri.path == _challengePath) {
        if (!_matches(proof, _proof(code, ['hello', token]))) {
          reply.statusCode = HttpStatus.unauthorized;
          return;
        }
        final now = DateTime.now();
        _challenges.removeWhere((_, expires) => !now.isBefore(expires));
        if (_challenges.length >= 32 || _executing) {
          reply.statusCode = HttpStatus.tooManyRequests;
          return;
        }
        final challenge = newTransferCode();
        _challenges[challenge] = now.add(const Duration(seconds: 30));
        reply.write(jsonEncode({
          'challenge': challenge,
          'proof': _proof(code, ['ready', token, challenge])
        }));
        return;
      }
      if (request.method != 'POST' ||
          request.uri.path != _actionPath ||
          request.contentLength != 0) {
        reply.statusCode = HttpStatus.badRequest;
        return;
      }
      final actionName = request.headers.value('x-qg-power-action');
      final action = PowerAction.values
          .where((item) => item.name == actionName)
          .firstOrNull;
      if (action == null) {
        reply.statusCode = HttpStatus.badRequest;
        return;
      }
      final expires = _challenges[token];
      if (expires == null ||
          !DateTime.now().isBefore(expires) ||
          !_matches(proof, _proof(code, ['act', token, action.name]))) {
        reply.statusCode = HttpStatus.unauthorized;
        return;
      }
      _challenges.remove(token);
      if (_executing) {
        reply.statusCode = HttpStatus.tooManyRequests;
        return;
      }
      _executing = true;
      try {
        if (await run(action)) {
          reply.statusCode = HttpStatus.accepted;
          reply.write(jsonEncode({
            'proof': _proof(code, ['accepted', token, action.name])
          }));
        } else {
          reply.statusCode = HttpStatus.internalServerError;
        }
      } finally {
        _executing = false;
      }
    } on Exception {
      reply.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await reply.close();
      } on IOException {/* The PC may be shutting down. */}
    }
  }

  static Future<bool> runOnWindows(PowerAction action) async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    try {
      final result = await Process.run(
          '$root\\System32\\shutdown.exe', action.windowsArguments);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

class PowerClient {
  const PowerClient();

  Future<void> submit(Uri address, String code, PowerAction action) async {
    if (!validTransferCode(code)) throw const FileTransferFailure('请核对远程电源码。');
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final hello = newTransferCode();
      final request =
          await client.getUrl(address.replace(path: _challengePath));
      request.followRedirects = false;
      request.headers.set('x-qg-power-nonce', hello);
      request.headers.set('x-qg-power-proof', _proof(code, ['hello', hello]));
      final ready =
          await _read(await request.close().timeout(_timeout), HttpStatus.ok);
      final challenge = ready['challenge'];
      if (challenge is! String ||
          !_nonce.hasMatch(challenge) ||
          !_matches(ready['proof'] as String?,
              _proof(code, ['ready', hello, challenge]))) {
        throw const FileTransferFailure('无法验证被控电脑。');
      }
      final command = await client.postUrl(address.replace(path: _actionPath));
      command.followRedirects = false;
      command.contentLength = 0;
      command.headers.set('x-qg-power-nonce', challenge);
      command.headers.set('x-qg-power-action', action.name);
      command.headers.set(
          'x-qg-power-proof', _proof(code, ['act', challenge, action.name]));
      final response = await _read(
          await command.close().timeout(_timeout), HttpStatus.accepted);
      if (!_matches(response['proof'] as String?,
          _proof(code, ['accepted', challenge, action.name]))) {
        throw const FileTransferFailure('无法确认被控电脑已接收操作。');
      }
    } on FileTransferFailure {
      rethrow;
    } on Exception {
      throw const FileTransferFailure('无法确认远程电源操作。请检查组网及被控电脑的设置。');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _read(
      HttpClientResponse response, int expected) async {
    if (response.statusCode != expected) {
      throw FileTransferFailure(switch (response.statusCode) {
        HttpStatus.forbidden => '对方电脑已关闭远程电源。',
        HttpStatus.unauthorized => '远程电源码不正确或已更换。',
        HttpStatus.tooManyRequests => '被控电脑正在处理其他电源操作。',
        _ => '远程电源操作未完成（${response.statusCode}）。',
      });
    }
    final body = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      if (body.length + chunk.length > 2048) throw const FormatException();
      body.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(body));
    if (data is! Map<String, dynamic>) throw const FormatException();
    return data;
  }
}
