import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/clipboard_sync_session.dart';
import 'package:lulu_remote/services/file_transfer_service.dart';
import 'package:lulu_remote/services/host_tools_service.dart';
import 'package:lulu_remote/services/host_hardware.dart';
import 'package:lulu_remote/services/remote_command.dart';

void main() {
  late HttpServer listener;
  late HostToolsServer server;
  late HostToolsClient client;
  late String clipboard;
  late List<String> forwarded;
  late bool streaming;
  late List<RemoteCommand> commands;

  setUp(() async {
    clipboard = '来自主机';
    forwarded = [];
    streaming = false;
    commands = [];
    final code = newTransferCode();
    server = HostToolsServer(
        code: code,
        streaming: () => streaming,
        sendWake: (mac) async => forwarded.add(mac),
        readDiagnostics: () async => '电脑名称：TEST-PC',
        runCommand: (query) async {
          commands.add(query);
          return '${query.command} 完成';
        },
        readHardware: () async => const HostHardware(
            cpu: 'TEST CPU',
            ramBytes: 17179869184,
            diskBytes: 107374182400,
            diskFreeBytes: 53687091200,
            os: 'Windows TEST'),
        readClipboard: () async => clipboard,
        writeClipboard: (value) async {
          clipboard = value;
        });
    listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listener.listen(server.handle);
    client = HostToolsClient('127.0.0.1', code, port: listener.port);
  });

  tearDown(() async => listener.close(force: true));

  test('remote commands require their own opt-in and the collaboration code',
      () async {
    server.diagnosticsEnabled = true;
    await expectLater(client.command(RemoteCommand.version),
        throwsA(isA<HostToolsException>()));
    server.commandsEnabled = true;
    final stranger =
        HostToolsClient('127.0.0.1', newTransferCode(), port: listener.port);
    await expectLater(stranger.command(RemoteCommand.hostname),
        throwsA(isA<HostToolsException>()));
    expect(await client.command(RemoteCommand.version), 'ver 完成');
    expect(commands, [RemoteCommand.version]);
    server.commandsEnabled = false;
    await expectLater(
        client.command(RemoteCommand.user), throwsA(isA<HostToolsException>()));
    expect(commands, [RemoteCommand.version]);
  });

  test('command parser accepts only fixed query names', () {
    expect(RemoteCommand.parse('hostname'), RemoteCommand.hostname);
    expect(RemoteCommand.parse('hostname & ver'), isNull);
    expect(RemoteCommand.parse('whoami /all'), isNull);
    expect(RemoteCommand.parse(''), isNull);
  });

  test('Windows executes the three queries and reports their exit code',
      () async {
    for (final query in [
      RemoteCommand.hostname,
      RemoteCommand.version,
      RemoteCommand.user,
    ]) {
      final output = await RemoteCommand.runOnWindows(query);
      expect(output.split('\n').first, isNotEmpty);
      expect(output.split('\n').length, greaterThan(1));
      expect(output, endsWith('退出码：0'));
    }
  }, skip: !Platform.isWindows);

  test('approved recipe validates a local executable and keeps arguments', () {
    expect(() => ApprovedWindowsCommand('cmd.exe', []), throwsFormatException);
    expect(() => ApprovedWindowsCommand(r'\\server\share\tool.exe', []),
        throwsFormatException);
    final approved = ApprovedWindowsCommand(
        r'C:\Program Files\tool.exe', ['example name', 'argument']);
    expect(ApprovedWindowsCommand.decode(approved.encode())?.arguments,
        ['example name', 'argument']);
    expect(RemoteCommand.parse('approved /c'), isNull);
  });

  test('executes a Windows preset through the authenticated host API',
      () async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final preset = ApprovedWindowsCommand(
        '$systemRoot\\System32\\cmd.exe', ['/d', '/c', 'echo', 'QG-PRESET-OK']);
    final service = HostToolsServer(
      code: server.code,
      readClipboard: () async => '',
      writeClipboard: (_) async {},
      runCommand: (query) =>
          RemoteCommand.runOnWindows(query, approved: preset),
    );
    final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => endpoint.close(force: true));
    endpoint.listen(service.handle);
    final testClient =
        HostToolsClient('127.0.0.1', service.code, port: endpoint.port);
    await expectLater(testClient.command(RemoteCommand.approved),
        throwsA(isA<HostToolsException>()));
    service.commandsEnabled = true;
    final output = await testClient.command(RemoteCommand.approved);
    expect(output, contains('QG-PRESET-OK'));
    expect(output, endsWith('退出码：0'));
  }, skip: !Platform.isWindows);

  test('wake relay rejects missing authorization and unregistered MACs',
      () async {
    await expectLater(
        client.wake('00:11:22:33:44:55'), throwsA(isA<HostToolsException>()));
    server.wakeTargets = {'00:11:22:33:44:55'};
    final stranger =
        HostToolsClient('127.0.0.1', newTransferCode(), port: listener.port);
    await expectLater(
        stranger.wake('00:11:22:33:44:55'), throwsA(isA<HostToolsException>()));
    await expectLater(
        client.wake('00:11:22:33:44:66'),
        throwsA(isA<HostToolsException>()
            .having((e) => e.message, 'message', contains('未登记'))));
    expect(forwarded, isEmpty);
  });

  test('registered MAC is forwarded, and removing it stops forwarding',
      () async {
    server.wakeTargets = {'00:AA:22:33:44:55'};
    await client.wake('00-aa-22-33-44-55');
    expect(forwarded, ['00:AA:22:33:44:55']);
    server.clipboardEnabled = true;
    server.wakeTargets = const {};
    await expectLater(
        client.wake('00:AA:22:33:44:55'), throwsA(isA<HostToolsException>()));
    expect(forwarded, ['00:AA:22:33:44:55']);
    expect(await client.readClipboard(), '来自主机');
  });

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

  test('automatic clipboard requires opt-in on the host and a live stream',
      () async {
    server.clipboardEnabled = true;
    await expectLater(
        client.watchClipboard(null), throwsA(isA<HostToolsException>()));
    server.clipboardSyncEnabled = true;
    await expectLater(
        client.watchClipboard(null), throwsA(isA<HostToolsException>()));
    streaming = true;
    expect((await client.watchClipboard(null)).text, isNull);
    streaming = false;
    await expectLater(
        client.pushClipboard('blocked'), throwsA(isA<HostToolsException>()));
    expect(clipboard, '来自主机');
  });

  test(
      'sync transfers new text in both directions without echo or initial copy',
      () async {
    server.clipboardEnabled = true;
    server.clipboardSyncEnabled = true;
    streaming = true;
    var local = '本机原有文本';
    final errors = <Object>[];
    final session = ClipboardSyncSession(
      client: client,
      readLocal: () async => local,
      writeLocal: (text) async => local = text,
      onError: errors.add,
    );
    addTearDown(session.stop);
    await session.start(interval: const Duration(hours: 1));
    await session.poll();
    expect(local, '本机原有文本');
    expect(clipboard, '来自主机');
    local = '本机复制';
    await session.poll();
    expect(clipboard, '本机复制');
    clipboard = '远端复制';
    await session.poll();
    expect(local, '远端复制');
    await session.poll();
    expect(local, clipboard);
    streaming = false;
    local = '断开后不发送';
    await session.poll();
    expect(errors, hasLength(1));
    expect(clipboard, '远端复制');
  });

  test('stopping during a clipboard poll discards the delayed result',
      () async {
    final fake = _DelayedClipboardClient();
    var local = 'local';
    final session = ClipboardSyncSession(
        client: fake,
        readLocal: () async => local,
        writeLocal: (text) async => local = text,
        onError: (error) => fail('$error'));
    addTearDown(session.stop);
    await session.start(interval: const Duration(hours: 1));
    final pending = session.poll();
    await fake.request.future;
    session.stop();
    fake.reply.complete((digest: List.filled(32, 1), text: 'remote'));
    await pending;
    expect(local, 'local');
  });

  test('fixed diagnostics only return a result when enabled', () async {
    server.clipboardEnabled = true;
    await expectLater(client.diagnostics(), throwsA(isA<HostToolsException>()));
    server.diagnosticsEnabled = true;
    expect(await client.diagnostics(), '电脑名称：TEST-PC');
    final raw = HttpClient();
    try {
      final request = await raw.post(
          '127.0.0.1', listener.port, '/v1/host-tools/arbitrary');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.forbidden);
      await response.drain<void>();
    } finally {
      raw.close(force: true);
    }
  });

  test('hardware opt-in returns the four expected measurements', () async {
    server.diagnosticsEnabled = true;
    await expectLater(client.hardware(), throwsA(isA<HostToolsException>()));
    server.hardwareEnabled = true;
    final hardware = await client.hardware();
    expect(hardware.summary, contains('TEST CPU'));
    expect(hardware.summary, contains('16.0 GiB'));
    expect(hardware.summary, contains('50.0 GiB 可用 / 100.0 GiB'));
    expect(hardware.summary, contains('Windows TEST'));
  });

  test('reads the real local Windows CIM snapshot', () async {
    final hardware = await HostHardware.readWindows();
    expect(hardware.cpu, isNotEmpty);
    expect(hardware.os, contains('Windows'));
    expect(hardware.ramBytes, greaterThan(0));
    expect(hardware.diskBytes, greaterThanOrEqualTo(hardware.diskFreeBytes));
  }, skip: !Platform.isWindows);
}

class _DelayedClipboardClient extends HostToolsClient {
  _DelayedClipboardClient() : super('127.0.0.1', '');
  final request = Completer<void>();
  final reply = Completer<({List<int> digest, String? text})>();

  @override
  Future<({List<int> digest, String? text})> watchClipboard(
      List<int>? digest) async {
    if (digest == null) return (digest: List.filled(32, 0), text: null);
    request.complete();
    return reply.future;
  }
}
