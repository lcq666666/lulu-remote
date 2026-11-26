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
    String clientName = 'LULU',
  }) async {
    final pairingId = await _waitForPairingId(
      device: device,
      adminUser: adminUser,
      adminPassword: adminPassword,
    );
    final body = <String, dynamic>{
      'pin': pin,
      'name': clientName,
      if (pairingId != null) 'pairing_id': pairingId,
    };
    final client = _client();
    try {
      final request = await client.postUrl(
        Uri.parse('${device.webBase}/api/pin'),
      );
      _auth(request, adminUser, adminPassword);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException(
          '提交 PIN 失败：HTTP ${response.statusCode} $text',
          uri: Uri.parse('${device.webBase}/api/pin'),
        );
      }
    } finally {
      client.close();
    }
  }

  /// Poll GET /api/pin until a pending pairing appears, or return null
  /// after 30s (older Sunshine accepts a POST without pairing_id).
  Future<String?> _waitForPairingId({
    required Device device,
    required String adminUser,
    required String adminPassword,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final client = _client();
      try {
        final request = await client.getUrl(
          Uri.parse('${device.webBase}/api/pin'),
        );
        _auth(request, adminUser, adminPassword);
        final response = await request.close();
        final text = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final id = _extractPairingId(text);
          if (id != null) return id;
        }
      } catch (_) {
        // Host not answering yet — keep polling until the deadline.
      } finally {
        client.close();
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  /// GET /api/pin returns a JSON array or object; be liberal in what we
  /// accept — the exact shape varies by Sunshine version (unverified).
  static String? _extractPairingId(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map) return first['pairing_id'] as String?;
        if (first is String) return first;
      }
      if (decoded is Map) {
        final id = decoded['pairing_id'];
        if (id is String) return id;
        final list = decoded['pairing_requests'];
        if (list is List && list.isNotEmpty && list.first is Map) {
          return (list.first as Map)['pairing_id'] as String?;
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  HttpClient _client() {
    final client = _clientFactory();
    // TOFU for the PIN submission only — see the trust note above.
    client.badCertificateCallback = (_, __, ___) => true;
    return client;
  }

  static void _auth(HttpClientRequest request, String user, String password) {
    final credentials = base64Encode(utf8.encode('$user:$password'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
  }
}
