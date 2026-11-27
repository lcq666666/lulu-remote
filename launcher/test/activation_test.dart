import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/app.dart';
import 'package:lulu_remote/screens/activation_screen.dart';
import 'package:lulu_remote/screens/home_screen.dart';
import 'package:lulu_remote/services/activation_service.dart';
import 'package:lulu_remote/services/machine_code_service.dart';
import 'package:lulu_remote/services/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final machine =
    MachineFingerprint.fromIdentifiers('windows', ['board', 'disk', 'guid']);

class MemoryStore extends SecureStore {
  String? token;
  @override
  Future<String?> readActivationToken() async => token;
  @override
  Future<void> writeActivationToken(String token) async => this.token = token;
  @override
  Future<void> deleteActivationToken() async => token = null;
}

class _FailedActivation extends ActivationService {
  _FailedActivation(this.error);
  final ActivationError error;
  @override
  Future<String> server() async => '127.0.0.1:8765';
  @override
  Future<ActivationState> activate(
          String key, String address, MachineFingerprint machine) async =>
      throw ActivationFailure(error);
}

String encoded(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('rejects every possible single-character substitution', () {
    const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    const key = 'LULU-2222-2222-2222-2222';
    expect(normalizeActivationKey(' ${key.toLowerCase()} '), key);
    for (var i = 5; i < key.length; i++) {
      if (key[i] == '-') continue;
      for (final c in alphabet.split('')) {
        if (c != key[i]) {
          expect(normalizeActivationKey(key.replaceRange(i, i + 1, c)), isNull);
        }
      }
    }
  });

  test('accepts one Windows component change and rejects two', () {
    expect(machine.code, matches(r'^(?:[0-9A-F]{4}-){3}[0-9A-F]{4}$'));
    expect(
        machine.matches(MachineFingerprint.fromIdentifiers(
            'windows', ['board', 'disk2', 'guid'])),
        isTrue);
    expect(
        machine.matches(MachineFingerprint.fromIdentifiers(
            'windows', [null, 'disk', 'guid'])),
        isTrue);
    expect(
        machine.matches(MachineFingerprint.fromIdentifiers(
            'windows', ['board2', 'disk2', 'guid'])),
        isFalse);
    expect(
        MachineFingerprint.fromIdentifiers(
            'windows', ['default string', '', null]).valid,
        isFalse);
    expect(
        machine
            .matches(MachineFingerprint.fromIdentifiers('android', ['board'])),
        isFalse);
  });

  test('offline boot verifies signature and hardware binding', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final verifier = ActivationVerifier(encoded(publicKey.bytes));
    final store = MemoryStore();
    MachineFingerprint local = machine;
    final service = ActivationService(
        store: store, verifier: verifier, readMachine: () async => local);
    expect((await service.load()).active, isFalse);
    final payload = utf8.encode(jsonEncode({
      'v': 1,
      'key_id': 1,
      'issued_at': 123,
      'machine_hash': machine.hash,
      'device': machine.toJson(),
    }));
    final signature = await algorithm.sign(payload, keyPair: keyPair);
    await store.writeActivationToken(
        '${encoded(payload)}.${encoded(signature.bytes)}');
    expect((await service.load()).active, isTrue);
    local = MachineFingerprint.fromIdentifiers(
        'windows', ['board2', 'disk2', 'guid']);
    expect((await service.load()).error, ActivationError.hardwareChanged);
    final tampered = List<int>.of(payload)..[0] = payload[0] ^ 1;
    expect(
        await verifier
            .fingerprint('${encoded(tampered)}.${encoded(signature.bytes)}'),
        isNull);
    await service.reset();
    expect(await store.readActivationToken(), isNull);
  });

  testWidgets('fresh install shows activation and leaves host stopped',
      (tester) async {
    var started = false;
    final service = ActivationService(
        store: MemoryStore(),
        verifier: ActivationVerifier(encoded(List.filled(32, 1))),
        readMachine: () async => machine);
    await tester.pumpWidget(
        LuluApp(activation: service, onActivated: () => started = true));
    await tester.pumpAndSettle();
    expect(find.byType(ActivationScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(started, isFalse);
  });

  const messages = {
    ActivationError.unreachable: '连不上激活服务器，请检查网络和组网，再重试。',
    ActivationError.wrongKey: '密钥不正确，请核对后重新输入。',
    ActivationError.usedKey: '该密钥已被使用，请找作者领新密钥。',
    ActivationError.hardwareChanged: '本机硬件有变化，请找作者重新领码。',
  };
  for (final entry in messages.entries) {
    testWidgets('activation page displays ${entry.key.name}', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: ActivationScreen(
        service: _FailedActivation(entry.key),
        state: ActivationState(machine: machine),
        onActivated: (_) {},
        onRetry: () {},
      )));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, '激活');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
    });
  }
}
