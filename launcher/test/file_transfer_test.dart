import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/file_transfer_host.dart';
import 'package:lulu_remote/services/file_transfer_service.dart';

void main() {
  late Directory root;
  late FileTransferServer receiver;
  late Uri endpoint;
  late String code;
  late FileTransferClient sender;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qg-file-test-');
    addTearDown(() => root.delete(recursive: true));
    code = newTransferCode();
    receiver = FileTransferServer(code: code, receiveDirectory: root);
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => listener.close(force: true));
    listener.listen(receiver.handle);
    endpoint = Uri(scheme: 'http', host: '127.0.0.1', port: listener.port);
    sender = FileTransferClient(bytesPerSecond: 0);
  });

  Future<String> sendBytes(String name, List<int> bytes, {String? withCode}) =>
      sender.send(
        endpoint: endpoint,
        code: withCode ?? code,
        name: name,
        length: bytes.length,
        openRead: () => Stream.value(bytes),
        onProgress: (_, __) {},
      );

  File received(String name) =>
      File('${root.path}${Platform.pathSeparator}$name');

  test('sends Unicode file names and preserves existing files', () async {
    const name = '实验结果.txt';
    final bytes = utf8.encode('组网文件传输');
    expect(await sendBytes(name, bytes), name);
    expect(await received(name).readAsBytes(), bytes);
    final nextName = await sendBytes(name, [1, 2, 3]);
    expect(nextName, isNot(name));
    expect(await received(nextName).readAsBytes(), [1, 2, 3]);
    expect(await received(name).readAsBytes(), bytes);
  });

  test('streams 100 MB and verifies the full file', () async {
    const size = 100 * 1000 * 1000;
    const name = 'sample.bin';
    final block =
        Uint8List.fromList(List.generate(64000, (index) => index % 251));
    Stream<List<int>> data() async* {
      for (var sent = 0; sent < size; sent += block.length) {
        final remaining = size - sent;
        yield remaining >= block.length
            ? block
            : Uint8List.sublistView(block, 0, remaining);
      }
    }

    var reported = 0;
    final saved = await sender.send(
      endpoint: endpoint,
      code: code,
      name: name,
      length: size,
      openRead: data,
      onProgress: (sent, _) => reported = sent,
    );
    expect(saved, name);
    expect(reported, size);
    expect(await received(name).length(), size);
    expect(await sha256.bind(received(name).openRead()).first,
        await sha256.bind(data()).first);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('rejects a wrong code or a disabled receiver', () async {
    await expectLater(
        sendBytes('denied.txt', [1], withCode: newTransferCode()),
        throwsA(isA<FileTransferFailure>().having(
            (failure) => failure.message, 'message', contains('接收码不正确'))));
    await receiver.disable();
    await expectLater(
        sendBytes('denied.txt', [1]),
        throwsA(isA<FileTransferFailure>()
            .having((failure) => failure.message, 'message', contains('已关闭'))));
    expect(await root.list().isEmpty, isTrue);
  });

  test('starts authentication for a file larger than the old 2 GiB cap',
      () async {
    await expectLater(
      sender.send(
        endpoint: endpoint,
        code: newTransferCode(),
        name: 'large.bin',
        length: 3 * 1024 * 1024 * 1024,
        openRead: () => Stream.value([1]),
        onProgress: (_, __) {},
      ),
      throwsA(isA<FileTransferFailure>()
          .having((failure) => failure.message, 'message', contains('接收码不正确'))),
    );
  });

  test('explains how to enable receiving when nothing is listening', () async {
    final closedListener =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final unavailable = endpoint.replace(port: closedListener.port);
    await closedListener.close(force: true);
    await expectLater(
      sender.send(
        endpoint: unavailable,
        code: code,
        name: 'denied.txt',
        length: 1,
        openRead: () => Stream.value([1]),
        onProgress: (_, __) {},
      ),
      throwsA(isA<FileTransferFailure>().having(
          (failure) => failure.message, 'message', contains('已开启「文件接收」'))),
    );
  });

  test('disabling drains and removes a stalled upload before the next chunk',
      () async {
    final block = Uint8List(65536);
    final continueUpload = Completer<void>();
    var readCount = 0;
    Stream<List<int>> data() async* {
      final isUpload = ++readCount == 2;
      yield block;
      if (isUpload) await continueUpload.future;
      yield block;
    }

    final transfer = sender.send(
      endpoint: endpoint,
      code: code,
      name: 'paused.bin',
      length: block.length * 2,
      openRead: data,
      onProgress: (_, __) {},
    );
    final rejection = expectLater(
      transfer,
      throwsA(isA<FileTransferFailure>()
          .having((failure) => failure.message, 'message', contains('已关闭'))),
    );
    try {
      var firstChunkSaved = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        final staged = await root
            .list(recursive: true)
            .where((entry) => entry is File)
            .cast<File>()
            .toList();
        if (staged.length == 1 &&
            await staged.single.length() == block.length) {
          firstChunkSaved = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(firstChunkSaved, isTrue);
      // Don't release the sender: disabling must wake up the server's
      // outstanding read rather than relying on a new chunk or idle timeout.
      await receiver.disable().timeout(const Duration(seconds: 4));
      expect(await root.list().isEmpty, isTrue);
    } finally {
      continueUpload.complete();
    }
    await rejection;
    expect(await root.list().isEmpty, isTrue);
  });

  test('rejects and cleans up a changed file', () async {
    var readCount = 0;
    await expectLater(
        sender.send(
          endpoint: endpoint,
          code: code,
          name: 'changed.bin',
          length: 1,
          openRead: () => Stream.value([readCount++]),
          onProgress: (_, __) {},
        ),
        throwsA(isA<FileTransferFailure>().having(
            (failure) => failure.message, 'message', contains('文件校验失败'))));
    expect(await root.list().isEmpty, isTrue);
  });

  test('accepts private overlay addresses and rejects unsafe paths', () {
    expect(isPrivateTransferAddress('100.110.0.1'), isTrue);
    expect(isPrivateTransferAddress('1.1.1.1'), isFalse);
    expect(isPrivateTransferAddress('127.0.0.1'), isFalse);
    for (final name in [
      '../escape',
      r'foo\escape',
      'report:stream',
      'NUL.txt',
      'file.',
      'name '
    ]) {
      expect(safeTransferName(name), isFalse, reason: name);
    }
  });
}
