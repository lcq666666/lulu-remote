import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/file_transfer_service.dart';
import 'package:lulu_remote/services/host_tools_service.dart';

void main() {
  late HttpServer listener;
  late HostToolsServer server;
  late HostToolsClient client;
  late String clipboard;

  setUp(() async {
    clipboard = '来自主机';
    final code = newTransferCode();
    server = HostToolsServer(
        code: code,
        readClipboard: () async => clipboard,
        writeClipboard: (value) async {
          clipboard = value;
        });
    listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listener.listen(server.handle);
    client = HostToolsClient('127.0.0.1', code, port: listener.port);
  });

  tearDown(() async => listener.close(force: true));

  test('manually exchanges UTF-8 clipboard text in both directions', () async {
    server.clipboardEnabled = true;
    expect(await client.readClipboard(), '来自主机');
    await client.writeClipboard('控制端\n文本');
    expect(clipboard, '控制端\n文本');
    expect(await client.readClipboard(), clipboard);
  });

  test('refuses access when disabled and rejects a wrong code', () async {
    await expectLater(
        client.readClipboard(),
        throwsA(isA<HostToolsException>()
            .having((e) => e.message, 'message', contains('未开启'))));
    server.clipboardEnabled = true;
    final stranger =
        HostToolsClient('127.0.0.1', newTransferCode(), port: listener.port);
    await expectLater(
        stranger.writeClipboard('不要替换'),
        throwsA(isA<HostToolsException>()
            .having((e) => e.message, 'message', contains('不正确'))));
    expect(clipboard, '来自主机');
  });

  test('bounds clipboard size', () async {
    server.clipboardEnabled = true;
    await expectLater(client.writeClipboard('汉' * (clipboardMaxBytes ~/ 3 + 1)),
        throwsA(isA<HostToolsException>()));
    expect(clipboard, '来自主机');
  });
}
