import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/pairing/client_identity.dart';
import 'package:lulu_remote/pairing/gamestream_crypto.dart';
import 'package:lulu_remote/pairing/pairing_errors.dart';
import 'package:lulu_remote/pairing/pairing_service.dart';
import 'package:lulu_remote/pairing/sunshine_pin_api.dart';
import 'package:lulu_remote/services/secure_store.dart';

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
}
