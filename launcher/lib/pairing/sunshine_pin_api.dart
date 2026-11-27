// SPDX-License-Identifier: GPL-3.0-only
// LULU Remote — Sunshine web UI PIN submission.
// Sunshine API docs: https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2api.html
//   GET  /api/pin  — lists the pending pairing request(s)
//   POST /api/pin  — {"pairing_id": "<id>", "pin": "<pin>", "name": "<client name>"}
// Auth: HTTP Basic with the Sunshine admin username/password.
// The admin credentials are entered once in LULU and stored only in the
// OS secure store (SecureStore); they are never logged or written to a file.

import 'dart:convert';
import 'dart:io';

import '../models/device.dart';

class SunshinePinApi {
  SunshinePinApi({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  /// Submit [pin] for the pending pairing session on [device].
  ///
  /// Order matters (see lib/pairing/README.md): the phase-1 `/pair`
  /// request must already be in flight — Sunshine parks it until this
  /// call arrives. This method polls GET /api/pin for up to 30 seconds
  /// waiting for a pending pairing_id, then POSTs.
  ///
  /// Trust note: at this point LULU has not yet received the server
  /// certificate (phase 1 is still parked), so the server cert cannot be
  /// pinned yet. The TLS connection is accepted on first use (TOFU) to
  /// the mesh address the user typed — the same trust the web UI offers
  /// when it shows a self-signed-cert warning. After the first pair,
  /// later calls should pin the stored server cert; that is a TODO in
  /// PairingService (phase 5 already pins).
  Future<void> submitPin({
    required Device device,
    required String pin,
    required String adminUser,
    required String adminPassword,
    required String requestName,
    String clientName = 'LULU',
  }) async {
    final pairingId = await _waitForPairingId(
      device: device,
      adminUser: adminUser,
      adminPassword: adminPassword,
      requestName: requestName,
    );
    final body = <String, dynamic>{
      'pin': pin,
      'name': clientName,
      'pairing_id': pairingId,
    };
    final client = _client();
    try {
      final authorization = await client.getUrl(
        Uri.parse('${device.webBase}/api/csrf-token'),
      );
      _auth(authorization, adminUser, adminPassword);
      final tokenResponse =
          await authorization.close().timeout(const Duration(seconds: 5));
      final tokenText = await tokenResponse
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      if (tokenResponse.statusCode != 200) {
        throw const HttpException('无法取得对方电脑的 PIN 提交授权。');
      }
      final tokenResult = jsonDecode(tokenText);
      final token = tokenResult is Map ? tokenResult['csrf_token'] : null;
      if (token is! String || token.isEmpty) {
        throw const HttpException('对方电脑没有返回 PIN 提交授权。');
      }
      final request = await client.postUrl(
        Uri.parse('${device.webBase}/api/pin'),
      );
      _auth(request, adminUser, adminPassword);
      request.headers.set('X-CSRF-Token', token);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw HttpException(
          '提交 PIN 失败：HTTP ${response.statusCode}',
          uri: Uri.parse('${device.webBase}/api/pin'),
        );
      }
      final result = jsonDecode(text);
      if (result is! Map || result['status'] != true) {
        throw const HttpException('对方电脑未接受本次 PIN，请重新配对。');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _waitForPairingId({
    required Device device,
    required String adminUser,
    required String adminPassword,
    required String requestName,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final client = _client();
      try {
        final request = await client.getUrl(
          Uri.parse('${device.webBase}/api/pin'),
        );
        _auth(request, adminUser, adminPassword);
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        final text = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const HttpException('对方电脑拒绝了管理账号验证，请检查账号和密码。');
        }
        if (response.statusCode != 200) {
          throw HttpException('无法读取对方的配对请求（HTTP ${response.statusCode}）。');
        }
        final id = _extractPairingId(text, requestName);
        if (id != null) return id;
      } finally {
        client.close(force: true);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw const HttpException('对方电脑没有显示本次配对请求，请检查地址后重试。');
  }

  static String? _extractPairingId(String text, String requestName) {
    final result = jsonDecode(text);
    if (result is! Map || result['pairings'] is! List) {
      throw const HttpException('对方电脑的配对接口版本不兼容。');
    }
    for (final request in result['pairings'] as List) {
      if (request is! Map || request['name'] != requestName) continue;
      final id = request['id'];
      if (id is String && RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(id)) return id;
    }
    return null;
  }

  HttpClient _client() {
    final client = _clientFactory();
    client.connectionTimeout = const Duration(seconds: 5);
    // TOFU for the PIN submission only — see the trust note above.
    client.badCertificateCallback = (_, __, ___) => true;
    return client;
  }

  static void _auth(HttpClientRequest request, String user, String password) {
    final credentials = base64Encode(utf8.encode('$user:$password'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
  }
}
