import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/activation_service.dart';
import 'package:lulu_remote/services/machine_code_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activation_test.dart' show MemoryStore, encoded;

void main() {
  test('requires authenticated readiness before sending a weekly review',
      () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => endpoint.close(force: true));
    var statusChecks = 0;
    var reviews = 0;
    var ready = false;
    var revoked = false;
    const token = 'test-token';
    endpoint.listen((request) async {
      final response = request.response;
      final Map<String, Object> data;
      if (request.method == 'GET' && request.uri.path == '/v1/status') {
        statusChecks++;
        final nonce = request.uri.queryParameters['nonce'];
        final signed = await algorithm.sign(
            utf8.encode('lulu-status-v1:${ready ? nonce : 'wrong-nonce'}'),
            keyPair: keyPair);
        data = {'ok': true, 'proof': encoded(signed.bytes)};
      } else if (request.method == 'POST' &&
          request.uri.path == '/v1/validate') {
        reviews++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        data = {'valid': !revoked, 'revoked': revoked};
        if (revoked) {
          final proof = await algorithm.sign(
              utf8.encode(
                  'lulu-revoked-v1:${body['nonce']}:${activationDigest(token)}'),
              keyPair: keyPair);
          data['proof'] = encoded(proof.bytes);
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        data = {};
      }
      response.write(jsonEncode(data));
      await response.close();
    });
    SharedPreferences.setMockInitialValues({
      'lulu_activation_server': 'http://127.0.0.1:${endpoint.port}',
    });
    final store = MemoryStore()..token = token;
    var clock = DateTime.utc(2026, 11, 28);
    final service = ActivationService(
        store: store,
        clock: () => clock,
        verifier: ActivationVerifier(encoded(publicKey.bytes)));
    expect(await service.checkRevocation(), isFalse);
    expect((statusChecks, reviews), (1, 0));
    expect(store.token, token);
    ready = true;
    expect(await service.checkRevocation(), isFalse);
    expect((statusChecks, reviews), (1, 0));
    clock = clock.add(const Duration(minutes: 5));
    expect(await service.checkRevocation(), isFalse);
    expect((statusChecks, reviews), (2, 1));
    revoked = true;
    clock = clock.add(const Duration(days: 6));
    expect(await service.checkRevocation(), isFalse);
    expect((statusChecks, reviews), (2, 1));
    expect(store.token, token);
    clock = clock.add(const Duration(days: 1));
    expect(await service.checkRevocation(), isTrue);
    expect((statusChecks, reviews), (3, 2));
    expect(store.token, isNull);
  });
}
