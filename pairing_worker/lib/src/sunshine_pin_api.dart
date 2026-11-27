// SPDX-License-Identifier: GPL-3.0-only
// LULU Remote — Sunshine web UI PIN submission.
// Sunshine API docs: https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2api.html
//   GET  /api/pin  — lists the pending pairing request(s)
//   POST /api/pin  — {"pairing_id": "<id>", "pin": "<pin>", "name": "<client name>"}
// Auth: HTTP Basic with the Sunshine admin username/password.
// The admin credentials are entered once in LULU and stored only in the
// launcher OS secure store. The worker never logs or persists them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';

class SunshinePinApi {
  SunshinePinApi({HttpClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  Future<void> verifyAccount({
    required Device device,
    required String adminUser,
    required String adminPassword,
  }) async {
    await listPairings(device, adminUser, adminPassword);
  }

  /// Submit [pin] for the pending pairing session on [device].
  ///
  /// Order matters (see pairing_worker/README.md): the phase-1 `/pair`
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
    void Function()? onRequestFound,
    void Function()? checkPendingRequest,
  }) async {
    final pairingId = await _waitForPairingId(
      device: device,
      adminUser: adminUser,
      adminPassword: adminPassword,
      requestName: requestName,
      checkPendingRequest: checkPendingRequest,
    );
    onRequestFound?.call();
    await approveRequest(
      device: device,
      pin: pin,
      adminUser: adminUser,
      adminPassword: adminPassword,
      pairingId: pairingId,
      clientName: clientName,
      checkPendingRequest: checkPendingRequest,
    );
  }

  Future<void> approveRequest({
    required Device device,
    required String pin,
    required String adminUser,
    required String adminPassword,
    required String pairingId,
    required String clientName,
    void Function()? checkPendingRequest,
  }) async {
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
      _requireManagementAccess(tokenResponse.statusCode);
      final tokenText = await tokenResponse
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final tokenResult = jsonDecode(tokenText);
      final token = tokenResult is Map ? tokenResult['csrf_token'] : null;
      if (token is! String || token.isEmpty) {
        throw const HttpException('对方电脑没有返回 PIN 提交授权。');
      }
      final request = await client.postUrl(
        Uri.parse('${device.webBase}/api/pin'),
      );
      checkPendingRequest?.call();
      _auth(request, adminUser, adminPassword);
      request.headers.set('X-CSRF-Token', token);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
            const Duration(seconds: 35),
            onTimeout: () => throw const HttpException(
              '等待 Sunshine 返回 PIN 提交结果超时。',
            ),
          );
      if (response.statusCode == 401) {
        _requireManagementAccess(response.statusCode);
      }
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
    void Function()? checkPendingRequest,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      checkPendingRequest?.call();
      final requests = await listPairings(device, adminUser, adminPassword);
      checkPendingRequest?.call();
      for (final request in requests) {
        if (request.name == requestName) return request.id;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    checkPendingRequest?.call();
    throw const HttpException('对方未登记本次配对请求。请确认对方开启了远程服务，再重试。');
  }

  Future<List<({String id, String name, String address})>> listPairings(
    Device device,
    String user,
    String password,
  ) async {
    final client = _client();
    try {
      final request =
          await client.getUrl(Uri.parse('${device.webBase}/api/pin'));
      _auth(request, user, password);
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      _requireManagementAccess(response.statusCode);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final result = jsonDecode(text);
      if (result is! Map || result['pairings'] is! List) {
        throw const HttpException('对方电脑的配对接口版本不兼容。');
      }
      return [
        for (final entry in result['pairings'] as List)
          if (entry is Map &&
              entry['id'] is String &&
              RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(entry['id'] as String))
            (
              id: entry['id'] as String,
              name: entry['name'] is String ? entry['name'] as String : '新设备',
              address:
                  entry['address'] is String ? entry['address'] as String : '',
            ),
      ];
    } on SocketException {
      throw HttpException(
          '远程服务可达，但无法访问对方的管理端口 ${device.webPort}。请检查对方的防火墙和管理端口。');
    } on TimeoutException {
      throw HttpException('等待对方的管理端口 ${device.webPort} 超时。请检查跨网访问权限和防火墙。');
    } on FormatException {
      throw const HttpException('对方的管理入口返回了无法识别的响应。');
    } finally {
      client.close(force: true);
    }
  }

  static void _requireManagementAccess(int status) {
    if (status == 401) {
      throw const HttpException('管理账号或密码未通过验证（401）。请填写被控电脑的 Sunshine 账号和密码。');
    }
    if (status == 403) {
      throw const HttpException(
          '对方的管理页面拒绝了这条网络连接（403）。请在被控电脑检查 Sunshine 的管理页面访问范围。');
    }
    if (status >= 300 && status < 400) {
      throw const HttpException('请先在被控电脑设置 Sunshine 管理账号。');
    }
    if (status != 200) {
      throw HttpException('对方的管理入口返回 HTTP $status。请检查管理端口和 Sunshine 版本。');
    }
  }

  HttpClient _client() {
    final client = _clientFactory();
    client.connectionTimeout = const Duration(seconds: 5);
    // Sunshine is reached over the user's LAN or Tailscale address. A
    // browser/system proxy must not intercept the pairing control channel.
    client.findProxy = (_) => 'DIRECT';
    // TOFU for the PIN submission only — see the trust note above.
    client.badCertificateCallback = (_, __, ___) => true;
    return client;
  }

  static void _auth(HttpClientRequest request, String user, String password) {
    request.followRedirects = false;
    final credentials = base64Encode(utf8.encode('$user:$password'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
  }
}
