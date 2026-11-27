import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/pairing/client_identity.dart';
import 'package:lulu_remote/pairing/gamestream_crypto.dart';
import 'package:lulu_remote/pairing/pairing_errors.dart';
import 'package:lulu_remote/pairing/pairing_service.dart';
import 'package:lulu_remote/pairing/sunshine_pin_api.dart';
import 'package:lulu_remote/services/secure_store.dart';
import 'package:pointycastle/export.dart';

class _TestDevice extends Device {
  _TestDevice(int port)
      : super(
            id: 'test',
            name: 'Test',
            meshAddress: '127.0.0.1',
            sunshinePort: port,
            webPort: port);

  @override
  String get webBase => 'http://127.0.0.1:$webPort';
}

void main() {
  for (final automatic in [false, true]) {
    test(
        'continues handshake while PIN response is pending (automatic: $automatic)',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final device = _TestDevice(server.port);
      final certificate =
          hexEncode(ascii.encode(ClientIdentity.generate().certPem));
      const pairingId = '0123456789abcdef0123456789abcdef';
      final pending = Completer<String>();
      final code = Completer<String>();
      final challenge = Completer<void>();
      final automaticAttempt = Completer<void>();
      var postCount = 0;
      final pairingConnections = <String?>[];
      HttpResponse? certificateResponse;
      addTearDown(() async {
        if (!challenge.isCompleted) challenge.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        final query = request.uri.queryParameters;
        final HttpResponse response = request.response;
        if (request.uri.path == '/pair') {
          pairingConnections
              .add(request.headers.value(HttpHeaders.connectionHeader));
        }
        if (query['phrase'] == 'getservercert') {
          certificateResponse = response;
          pending.complete(query['devicename']!);
          return;
        }
        if (request.method == 'POST') {
          await request.drain<void>();
          postCount++;
          if (!automatic && postCount == 1) {
            response.statusCode = 500;
            await response.close();
            automaticAttempt.complete();
            return;
          }
          certificateResponse!.write(
            '<root status_code="200"><paired>1</paired><plaincert>$certificate</plaincert></root>',
          );
          await certificateResponse!.close();
          await challenge.future;
          response.write('{"status":true}');
        } else if (query.containsKey('clientchallenge')) {
          challenge.complete();
          response.write('<root status_code="200"><paired>0</paired></root>');
        } else if (request.uri.path == '/api/csrf-token') {
          response.write('{"csrf_token":"test-token"}');
        } else if (request.uri.path == '/api/pin') {
          response.write(jsonEncode({
            'pairings': [
              if (pending.isCompleted)
                {'id': pairingId, 'name': await pending.future},
            ]
          }));
        } else {
          response.write(
              '<root status_code="200"><appversion>7</appversion></root>');
        }
        await response.close();
      });
      final result = PairingService(secureStore: SecureStore()).pair(
        device: device,
        adminUser: 'test',
        adminPassword: 'test',
        onProgress: (progress) {
          if (!code.isCompleted && progress.pin != null) {
            code.complete(progress.pin!);
          }
        },
      );
      final verifiesChallenge = expectLater(
          result,
          throwsA(
            isA<PairingTransport>()
                .having((error) => error.message, 'message', contains('第 2 步')),
          ));
      if (!automatic) {
        await automaticAttempt.future.timeout(const Duration(seconds: 5));
        final api = SunshinePinApi();
        final name = await pending.future.timeout(const Duration(seconds: 5));
        final requests = await api.listPairings(device, 'test', 'test');
        expect(requests.single.name, name);
        await api
            .approveRequest(
              device: device,
              pin: await code.future,
              adminUser: 'test',
              adminPassword: 'test',
              pairingId: requests.single.id,
              clientName: name,
            )
            .timeout(const Duration(seconds: 6));
      }
      await verifiesChallenge.timeout(const Duration(seconds: 8));
      expect(challenge.isCompleted, isTrue);
      expect(pairingConnections, ['close', 'close']);
    });
  }

  test('completes pairing and mutual TLS with a 0.1.5 client certificate',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureStore();
    final client = await ClientIdentity.loadOrGenerate(store);
    // Preserve the previously stored identity when upgrading from 0.1.5.
    final clientCert = client.certDer;
    final legacySigner = RSASigner(SHA256Digest(), '0609608648016503040301')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(client.privateKey));
    final legacySignature =
        legacySigner.generateSignature(derFirstChildRaw(clientCert)).bytes;
    clientCert.setRange(clientCert.length - legacySignature.length,
        clientCert.length, legacySignature);
    final clientPem = derToPem(clientCert, 'CERTIFICATE');
    await store.writeClientCertPem(clientPem);
    final host = ClientIdentity.generate();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(ascii.encode(host.certPem))
      ..usePrivateKeyBytes(ascii.encode(host.keyPem))
      ..setClientAuthoritiesBytes(ascii.encode(clientPem))
      ..setTrustedCertificatesBytes(ascii.encode(clientPem));
    final https = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
    );
    addTearDown(() => https.close(force: true));
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    final device = _TestDevice(http.port);
    final tlsRequests = <String>[];
    var hostAuthorized = false;

    https.listen((request) async {
      expect(hostAuthorized, isTrue);
      expect(request.certificate?.der, orderedEquals(clientCert));
      tlsRequests.add(request.uri.path);
      request.response.write(request.uri.path == '/pair'
          ? '<root status_code="200"><paired>1</paired></root>'
          : '<root status_code="200"><App><AppTitle>Desktop</AppTitle>'
              '<ID>42</ID></App></root>');
      await request.response.close();
    });

    const pairingId = '0123456789abcdef0123456789abcdef';
    HttpResponse? pendingCertificate;
    String? requestName;
    late Uint8List salt;
    late Uint8List aesKey;
    late Uint8List clientHash;
    final serverSecret = randomBytes(16);
    final serverChallenge = randomBytes(16);
    final hostCert = hexEncode(ascii.encode(host.certPem));

    http.listen((request) async {
      final query = request.uri.queryParameters;
      final response = request.response;
      String body;
      if (query['phrase'] == 'getservercert') {
        pendingCertificate = response;
        requestName = query['devicename'];
        salt = hexDecode(query['salt']!);
        expect(query['clientcert'], hexEncode(ascii.encode(clientPem)));
        return;
      } else if (request.method == 'POST') {
        final data = jsonDecode(await utf8.decoder.bind(request).join());
        expect(data['pairing_id'], pairingId);
        aesKey = deriveAesKey(salt, data['pin'] as String);
        pendingCertificate!.write('<root status_code="200"><paired>1</paired>'
            '<plaincert>$hostCert</plaincert></root>');
        await pendingCertificate!.close();
        body = '{"status":true}';
      } else if (query.containsKey('clientchallenge')) {
        final challenge = aesEcb(aesKey, hexDecode(query['clientchallenge']!),
            encrypt: false);
        final hash = sha256(Uint8List.fromList([
          ...challenge,
          ...extractCertSignature(host.certDer),
          ...serverSecret,
        ]));
        final encrypted = aesEcb(
            aesKey, Uint8List.fromList([...hash, ...serverChallenge]),
            encrypt: true);
        body = '<root status_code="200"><paired>1</paired>'
            '<challengeresponse>${hexEncode(encrypted)}</challengeresponse></root>';
      } else if (query.containsKey('serverchallengeresp')) {
        clientHash = aesEcb(aesKey, hexDecode(query['serverchallengeresp']!),
            encrypt: false);
        final signature = rsaSignSha256(host.privateKey, serverSecret);
        final pairingSecret = hexEncode(Uint8List.fromList([
          ...serverSecret,
          ...signature,
        ]));
        body = '<root status_code="200"><paired>1</paired>'
            '<pairingsecret>$pairingSecret</pairingsecret></root>';
      } else if (query.containsKey('clientpairingsecret')) {
        final secretAndSignature = hexDecode(query['clientpairingsecret']!);
        final secret = secretAndSignature.sublist(0, 16);
        expect(
            clientHash,
            orderedEquals(sha256(Uint8List.fromList([
              ...serverChallenge,
              ...legacySignature,
              ...secret,
            ]))));
        hostAuthorized = rsaVerifySha256(
            client.publicKey, secret, secretAndSignature.sublist(16));
        body = '<root status_code="200">'
            '<paired>${hostAuthorized ? 1 : 0}</paired></root>';
      } else if (request.uri.path == '/api/csrf-token') {
        body = '{"csrf_token":"test-token"}';
      } else if (request.uri.path == '/api/pin') {
        body = jsonEncode({
          'pairings': [
            if (requestName != null) {'id': pairingId, 'name': requestName},
          ],
        });
      } else {
        body = '<root status_code="200"><appversion>7</appversion>'
            '<HttpsPort>${https.port}</HttpsPort></root>';
      }
      response.write(body);
      await response.close();
    });

    final phases = <PairingPhase>[];
    final result = await PairingService(secureStore: store)
        .pair(
          device: device,
          adminUser: 'test',
          adminPassword: 'test',
          onProgress: (progress) => phases.add(progress.phase),
        )
        .timeout(const Duration(seconds: 20));
    expect(
        phases,
        containsAllInOrder([
          PairingPhase.verifying,
          PairingPhase.confirmingTls,
          PairingPhase.saving,
          PairingPhase.done,
        ]));
    expect(tlsRequests, ['/pair', '/applist']);
    expect(result.device.paired, isTrue);
    expect(result.device.appId, 42);
    expect(await store.readServerCertHex(device.id), hexEncode(host.certDer));
  });
}
