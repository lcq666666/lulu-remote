import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/file_transfer_service.dart';
import 'package:lulu_remote/services/power_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('remote power is off by default and can be turned off again', () async {
    SharedPreferences.setMockInitialValues({});
    final access = PowerAccess.instance;
    expect(await access.isEnabled(), isFalse);
    await access.setEnabled(true);
    expect(await access.isEnabled(), isTrue);
    await access.setEnabled(false);
    expect(await access.isEnabled(), isFalse);
  });

  test('authorizes only a selected fixed power action', () async {
    final code = newTransferCode();
    final actions = <PowerAction>[];
    final server = PowerServer(
        code: code,
        run: (action) async {
          actions.add(action);
          return true;
        });
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => listener.close(force: true));
    listener.listen(server.handle);
    final address = Uri(scheme: 'http', host: '127.0.0.1', port: listener.port);
    const client = PowerClient();
    await expectLater(
        client.submit(address, newTransferCode(), PowerAction.shutdown),
        throwsA(isA<FileTransferFailure>()));
    expect(actions, isEmpty);
    await client.submit(address, code, PowerAction.restart);
    await client.submit(address, code, PowerAction.shutdown);
    await client.submit(address, code, PowerAction.signOut);
    expect(actions, PowerAction.values);
    server.enabled = false;
    await expectLater(client.submit(address, code, PowerAction.signOut),
        throwsA(isA<FileTransferFailure>()));
    expect(actions, PowerAction.values);
    expect(PowerAction.restart.windowsArguments, ['/r', '/t', '0']);
    expect(PowerAction.shutdown.windowsArguments, ['/s', '/t', '0']);
    expect(PowerAction.signOut.windowsArguments, ['/l']);
  });
}
