import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/pairing_worker_client.dart';

String reply(String event, [Map<String, Object?> fields = const {}]) =>
    jsonEncode({'version': 1, 'event': event, ...fields});

void main() {
  final device = Device(id: 'host', name: 'PC', meshAddress: '127.0.0.1');
  const storage = FlutterSecureStorage();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'lulu_client_cert_pem': 'existing cert',
      'lulu_client_key_pem': 'existing key',
      'lulu_client_key_json': 'existing components',
      'lulu_uniqueid': 'existing ID',
    });
  });

  test('uses stored identity and receives PIN, host secrets and paired state',
      () async {
    final closed = Completer<void>();
    final client = PairingWorkerClient(exchange: (request) async* {
      final decoded = jsonDecode(request) as Map<String, dynamic>;
      expect(decoded['operation'], 'pair');
      expect(decoded['identity'], {
        'clientCertPem': 'existing cert',
        'clientKeyPem': 'existing key',
        'clientKeyJson': 'existing components',
        'uniqueId': 'existing ID',
      });
      try {
        yield reply('progress', {
          'phase': 'waitingForPin',
          'message': 'waiting',
          'pin': '0074',
          'requestName': 'pending',
        });
        yield reply('store', {'field': 'sunshineUser', 'value': 'test'});
        yield reply('store', {'field': 'serverCertHex', 'value': 'beef'});
        yield reply('result', {'appId': 12, 'hostUuid': 'test-host'});
        fail('The launcher should stop reading after the terminal event.');
      } finally {
        closed.complete();
      }
    });
    final progress = <PairingProgress>[];
    final result = await client.pair(
      device: device,
      adminUser: 'test',
      adminPassword: 'fake password',
      onProgress: progress.add,
    );
    expect(result.paired, isTrue);
    expect(result.appId, 12);
    expect(result.hostUuid, 'test-host');
    expect(progress.single.phase, PairingPhase.waitingForPin);
    expect(progress.single.pin, '0074');
    expect(progress.single.requestName, 'pending');
    expect(await storage.read(key: 'lulu_host_sunshine_user'), 'test');
    expect(await storage.read(key: 'lulu_host_server_cert_hex'), 'beef');
    expect(await storage.read(key: 'lulu_host_sunshine_password'), isNull);
    expect(closed.isCompleted, isTrue);
  });

  test('uses preexisting storage keys for new identity fields', () async {
    final client = PairingWorkerClient(exchange: (_) async* {
      yield reply('store', {'field': 'clientCertPem', 'value': 'new cert'});
      yield reply('store', {'field': 'clientKeyPem', 'value': 'new key'});
      yield reply(
          'store', {'field': 'clientKeyJson', 'value': 'new components'});
      yield reply('store', {'field': 'uniqueId', 'value': 'new ID'});
      yield reply('result');
    });
    await client.pair(device: device, adminUser: 'test', adminPassword: 'fake');
    expect(await storage.read(key: 'lulu_client_cert_pem'), 'new cert');
    expect(await storage.read(key: 'lulu_client_key_pem'), 'new key');
    expect(await storage.read(key: 'lulu_client_key_json'), 'new components');
    expect(await storage.read(key: 'lulu_uniqueid'), 'new ID');
  });

  test('keeps worker failures readable and allows retry after a failure',
      () async {
    var attempts = 0;
    final client = PairingWorkerClient(exchange: (_) async* {
      if (++attempts == 1) {
        yield reply('error', {'message': '错误的管理账号或密码。'});
      } else {
        yield reply('result');
      }
    });
    Future<Device> pair() =>
        client.pair(device: device, adminUser: 'test', adminPassword: 'fake');
    await expectLater(
        pair(),
        throwsA(isA<PairingFailure>().having(
          (failure) => failure.message,
          'message',
          '错误的管理账号或密码。',
        )));
    expect((await pair()).paired, isTrue);
  });

  test('does not surface raw IPC errors and reports early worker exit',
      () async {
    for (final exchange in <PairingExchange>[
      (_) => Stream.value('invalid JSON with an example secret'),
      (_) => const Stream.empty(),
    ]) {
      final client = PairingWorkerClient(exchange: exchange);
      await expectLater(
        client.verifyAccount(
            device: device, adminUser: 'test', adminPassword: 'fake'),
        throwsA(isA<PairingFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(contains('配对组件'), isNot(contains('example secret'))),
        )),
      );
    }
  });

  final exe = Platform.environment['LULU_PAIRING_TEST_EXE'];
  if (exe != null) {
    test('Windows worker exchanges a reply over anonymous pipes', () async {
      final responses = exchangeWithPairingExecutable(
        exe,
        jsonEncode({'version': 1, 'operation': 'ping'}),
      );
      expect(await responses.single, reply('result'));
    });
  }
}
