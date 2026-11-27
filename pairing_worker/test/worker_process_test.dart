// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lulu_pairing_worker/pairing_worker.dart';
import 'package:lulu_pairing_worker/src/client_identity.dart';
import 'package:lulu_pairing_worker/src/gamestream_crypto.dart';
import 'package:test/test.dart';

void main() {
  test('rejects an unknown protocol version without echoing the input',
      () async {
    final replies = <String>[];
    await runPairingRequest('{"version":2,"password":"example"}', replies.add);
    expect(jsonDecode(replies.single)['event'], 'error');
    expect(replies.single, isNot(contains('example')));
  });

  final exe = Platform.environment['LULU_PAIRING_TEST_EXE'];
  for (final useExe in [false, if (exe != null) true]) {
    test('streams PIN, auto-submits it, and saves host metadata (exe: $useExe)',
        () async {
      final host = ClientIdentity.generate();
      final context = SecurityContext()
        ..useCertificateChainBytes(ascii.encode(host.certPem))
        ..usePrivateKeyBytes(ascii.encode(host.keyPem));
      final https =
          await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await http.close(force: true);
        await https.close(force: true);
      });
      const expectedPairingId = '0123456789abcdef0123456789abcdef';
      final pending = Completer<HttpRequest>();
      final clientVerified = Completer<void>();
      final postedPin = Completer<String>();
      final hostSecret = Uint8List(16)..fillRange(0, 16, 42);
      final hostChallenge = Uint8List(16)..fillRange(0, 16, 7);
      late Uint8List aesKey;
      late Uint8List clientCert;
      late Uint8List expectedClientHash;
      var tlsConfirmed = false;
      var posts = 0;
      Future<void> xml(HttpResponse response, String content) async {
        response.write('<root status_code="200">$content</root>');
        await response.close();
      }

      http.listen((request) async {
        final query = request.uri.queryParameters;
        final response = request.response;
        if (request.uri.path == '/serverinfo') {
          await xml(response,
              '<HttpsPort>${https.port}</HttpsPort><uuid>fake-host</uuid>');
        } else if (query['phrase'] == 'getservercert') {
          clientCert = pemToDer(ascii.decode(hexDecode(query['clientcert']!)));
          pending.complete(request);
        } else if (query.containsKey('clientchallenge')) {
          final clientChallenge = aesEcb(
              aesKey, hexDecode(query['clientchallenge']!),
              encrypt: false);
          final hostHash = sha256(Uint8List.fromList([
            ...clientChallenge,
            ...extractCertSignature(host.certDer),
            ...hostSecret,
          ]));
          final challengeResponse = aesEcb(
              aesKey, Uint8List.fromList([...hostHash, ...hostChallenge]),
              encrypt: true);
          await xml(response,
              '<paired>1</paired><challengeresponse>${hexEncode(challengeResponse)}</challengeresponse>');
        } else if (query.containsKey('serverchallengeresp')) {
          expectedClientHash = aesEcb(
              aesKey, hexDecode(query['serverchallengeresp']!),
              encrypt: false);
          final secret = hexEncode(Uint8List.fromList([
            ...hostSecret,
            ...rsaSignSha256(host.privateKey, hostSecret),
          ]));
          await xml(response,
              '<paired>1</paired><pairingsecret>$secret</pairingsecret>');
        } else {
          final proof = hexDecode(query['clientpairingsecret']!);
          final secret = proof.sublist(0, 16);
          expect(
              rsaVerifySha256(extractRsaPublicKeyFromCert(clientCert), secret,
                  proof.sublist(16)),
              isTrue);
          expect(
              sha256(Uint8List.fromList([
                ...hostChallenge,
                ...extractCertSignature(clientCert),
                ...secret,
              ])),
              expectedClientHash);
          clientVerified.complete();
          await xml(response, '<paired>1</paired>');
        }
      });
      https.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/pair':
            expect(request.uri.queryParameters['phrase'], 'pairchallenge');
            expect(clientVerified.isCompleted, isTrue);
            tlsConfirmed = true;
            await xml(response, '<paired>1</paired>');
          case '/applist':
            expect(tlsConfirmed, isTrue);
            await xml(response,
                '<App><AppTitle>Desktop</AppTitle><ID>123</ID></App>');
          case '/api/csrf-token':
            response.write('{"csrf_token":"test-token"}');
            await response.close();
          case '/api/pin':
            expect(
                request.headers.value('authorization'), 'Basic dGVzdDp0ZXN0');
            if (request.method == 'GET') {
              response.write(jsonEncode({
                'pairings': [
                  if (pending.isCompleted)
                    {
                      'id': expectedPairingId,
                      'name': (await pending.future)
                          .uri
                          .queryParameters['devicename'],
                    },
                ]
              }));
            } else {
              posts++;
              expect(request.headers.value('x-csrf-token'), 'test-token');
              final body =
                  jsonDecode(await utf8.decoder.bind(request).join()) as Map;
              expect(body['pairing_id'], expectedPairingId);
              postedPin.complete(body['pin'] as String);
              final phase1 = await pending.future;
              aesKey = deriveAesKey(
                  hexDecode(phase1.uri.queryParameters['salt']!),
                  await postedPin.future);
              await xml(phase1.response,
                  '<paired>1</paired><plaincert>${hexEncode(ascii.encode(host.certPem))}</plaincert>');
              await clientVerified.future;
              response.write('{"status":true}');
            }
            await response.close();
          default:
            fail('Unexpected mock host request: ${request.uri.path}');
        }
      });
      final request = jsonEncode({
        'version': 1,
        'operation': 'pair',
        'target': {
          'id': 'host',
          'name': 'Mock Sunshine',
          'address': '127.0.0.1',
          'port': http.port,
          'webPort': https.port,
          'app': 'Desktop',
        },
        'user': 'test',
        'password': 'test',
        'identity': {},
      });
      final replies = <Map<String, dynamic>>[];
      void save(String value) =>
          replies.add(jsonDecode(value) as Map<String, dynamic>);
      if (useExe) {
        final child = await Process.start(exe!, []);
        addTearDown(() => child.kill());
        final stderr = child.stderr.drain<void>();
        child.stdin.writeln(request);
        await child.stdin.close();
        await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(save);
        expect(await child.exitCode, 0);
        await stderr;
      } else {
        await runPairingRequest(request, save);
      }
      expect(replies.where((it) => it['event'] == 'error'), isEmpty);
      final phases = replies.where((it) => it['event'] == 'progress').toList();
      final waiting = phases.firstWhere((it) => it['phase'] == 'waitingForPin');
      expect(waiting['pin'], matches(r'^\d{4}$'));
      expect(waiting['pin'], await postedPin.future);
      expect(posts, 1);
      expect(phases.last['phase'], 'done');
      expect(
          replies
              .where((it) => it['event'] == 'store')
              .map((it) => it['field']),
          containsAll([
            'clientCertPem',
            'clientKeyPem',
            'clientKeyJson',
            'uniqueId',
            'sunshineUser',
            'serverCertHex',
          ]));
      expect(replies.last, {
        'version': 1,
        'event': 'result',
        'appId': 123,
        'hostUuid': 'fake-host'
      });
    });
  }
}
