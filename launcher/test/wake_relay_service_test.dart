import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/file_transfer_service.dart';
import 'package:lulu_remote/services/wake_relay_service.dart';

void main() {
  test('relays only to a registered MAC with the right key and while enabled',
      () async {
    const mac = '02:12:34:AB:CD:EF';
    final key = newTransferCode();
    final calls = <String>[];
    final server = WakeRelayServer(
        code: key, sendWake: (address) async => calls.add(address));
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => listener.close(force: true));
    listener.listen(server.handle);
    final client = WakeRelayClient('127.0.0.1', key, port: listener.port);
    final wrong =
        WakeRelayClient('127.0.0.1', newTransferCode(), port: listener.port);
    final denied = throwsA(isA<WakeRelayException>());
    await expectLater(client.wake(mac), denied);
    server.wakeTargets = {mac};
    await expectLater(wrong.wake(mac), denied);
    await expectLater(client.wake('02:12:34:AB:CD:11'), denied);
    expect(calls, isEmpty);
    await client.wake('02-12-34-ab-cd-ef');
    expect(calls, [mac]);
    server.active = false;
    await expectLater(client.wake(mac), denied);
    expect(calls, [mac]);
  });
}
