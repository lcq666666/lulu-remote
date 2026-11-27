import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/activation_service.dart';
import 'package:lulu_remote/services/machine_code_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activation_test.dart' show MemoryStore;

void main() {
  final executable = Platform.environment['LULU_AUTH_TEST_EXE'];
  test('Go server and Flutter client activate, start offline and revoke',
      () async {
    SharedPreferences.setMockInitialValues({});
    final data = await Directory.systemTemp.createTemp('lulu-activation-test-');
    Process? running;
    Future<void> stopServer() async {
      final process = running;
      if (process == null) return;
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      running = null;
    }

    addTearDown(() async {
      await stopServer();
      await data.delete(recursive: true);
    });

    Future<String> cli(List<String> args) async {
      final result =
          await Process.run(executable!, ['--data-dir', data.path, ...args]);
      // Output may include a test redemption key. Do not use it as a failure diagnostic.
      expect(result.exitCode, 0, reason: 'Go CLI ${args.first} failed');
      return (result.stdout as String).trim();
    }

    final public = await cli(['init']);
    final key = await cli(['keys', 'generate']);
    final spareKey = await cli(['keys', 'generate']);
    final replacementKey = await cli(['keys', 'generate']);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final host = '127.0.0.1:$port';

    Future<void> startServer() async {
      final process = await Process.start(
          executable!, ['--data-dir', data.path, 'serve', '--listen', host]);
      running = process;
      final ready = Completer<void>();
      process.stdout.listen((_) {
        if (!ready.isCompleted) ready.complete();
      });
      unawaited(process.stderr.drain<void>());
      await ready.future.timeout(const Duration(seconds: 10));
    }

    final windows = MachineFingerprint.fromIdentifiers(
        'windows', ['board', 'disk', 'guid']);
    final android =
        MachineFingerprint.fromIdentifiers('android', ['android-id']);
    final verifier = ActivationVerifier(public);
    final store = MemoryStore();
    var now = DateTime.utc(2026, 11, 28);
    final service = ActivationService(
        store: store,
        readMachine: () async => windows,
        verifier: verifier,
        clock: () => now);
    final second = ActivationService(
        store: MemoryStore(),
        readMachine: () async => android,
        verifier: verifier,
        clock: () => now);
    Future<void> expectError(
            Future<ActivationState> activation, ActivationError error) =>
        expectLater(
            activation,
            throwsA(isA<ActivationFailure>()
                .having((e) => e.error, 'error', error)));

    await startServer();
    expect((await service.load()).active, isFalse);
    await expectError(
        service.activate('wrong', host, windows), ActivationError.wrongKey);
    await expectError(service.activate(key, '1.1.1.1:8765', windows),
        ActivationError.unreachable);
    final fake = ActivationService(
        store: MemoryStore(),
        verifier:
            ActivationVerifier('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'));
    await expectError(
        fake.activate(key, host, windows), ActivationError.invalidServer);
    expect((await service.activate(key, host, windows)).active, isTrue);
    await expectError(
        second.activate(key, host, android), ActivationError.usedKey);
    expect((await second.activate(spareKey, host, android)).active, isTrue);
    await stopServer();
    final bootedOffline = ActivationService(
        store: store,
        readMachine: () async => windows,
        verifier: verifier,
        clock: () => now);
    expect((await bootedOffline.load()).active, isTrue);
    now = now.add(const Duration(days: 7));
    expect(await bootedOffline.checkRevocation(), isFalse);
    expect((await bootedOffline.load()).active, isTrue);

    await cli(['devices', 'revoke', windows.hash]);
    await startServer();
    expect(await bootedOffline.checkRevocation(), isFalse,
        reason: 'weekly interval');
    now = now.add(const Duration(days: 7));
    expect(await bootedOffline.checkRevocation(), isTrue);
    expect(await store.readActivationToken(), isNull);
    expect((await bootedOffline.load()).error, ActivationError.revoked);
    await expectError(bootedOffline.activate(replacementKey, host, windows),
        ActivationError.revoked);
    expect(
        (await second.activate(replacementKey, host, android)).active, isTrue,
        reason: 'revoked devices do not consume unused keys');
  },
      skip: executable == null
          ? 'Build lulu-auth and set LULU_AUTH_TEST_EXE'
          : false);
}
