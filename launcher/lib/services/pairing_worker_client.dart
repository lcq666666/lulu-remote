import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/device.dart';
import 'secure_store.dart';

enum PairingPhase {
  checkingClient,
  checkingNetwork,
  checkingHost,
  checkingAccount,
  starting,
  waitingForPin,
  submittingPin,
  challenging,
  verifying,
  confirmingTls,
  saving,
  done,
}

class PairingProgress {
  const PairingProgress(this.phase, this.message, {this.pin, this.requestName});

  final PairingPhase phase;
  final String message;
  final String? pin;
  final String? requestName;
}

class PairingFailure implements Exception {
  const PairingFailure(this.message);

  final String message;
}

typedef PairingExchange = Stream<String> Function(String request);
typedef PairingRequest = ({String id, String name, String address});

/// The launcher side of the local IPC protocol. Identity and per-host secrets
/// continue to use the same system secure storage keys as earlier versions.
class PairingWorkerClient {
  PairingWorkerClient({SecureStore? secureStore, PairingExchange? exchange})
      : _secureStore = secureStore ?? SecureStore(),
        _exchange = exchange ?? _platformExchange;

  final SecureStore _secureStore;
  final PairingExchange _exchange;
  static bool _pairing = false;

  Future<Device> pair({
    required Device device,
    required String adminUser,
    required String adminPassword,
    void Function(PairingProgress)? onProgress,
  }) async {
    if (_pairing) throw const PairingFailure('已有一个配对正在进行，请稍后重试。');
    _pairing = true;
    try {
      final result = await _call('pair', device, adminUser, adminPassword,
          fields: {
            'identity': {
              'clientCertPem': await _secureStore.readClientCertPem(),
              'clientKeyPem': await _secureStore.readClientKeyPem(),
              'clientKeyJson': await _secureStore.readClientKeyJson(),
              'uniqueId': await _secureStore.readUniqueId(),
            },
          },
          onProgress: onProgress);
      return device.copyWith(
        paired: true,
        appId: result['appId'] as int?,
        hostUuid: result['hostUuid'] as String?,
      );
    } finally {
      _pairing = false;
    }
  }

  Future<void> verifyAccount({
    required Device device,
    required String adminUser,
    required String adminPassword,
  }) async {
    await _call('verifyAccount', device, adminUser, adminPassword);
  }

  Future<List<PairingRequest>> listPairings(
      Device device, String user, String password) async {
    final result = await _call('listPairings', device, user, password);
    return [
      for (final request in result['requests'] as List<dynamic>)
        (
          id: request['id'] as String,
          name: request['name'] as String,
          address: request['address'] as String
        ),
    ];
  }

  Future<void> approveRequest({
    required Device device,
    required String pin,
    required String adminUser,
    required String adminPassword,
    required String pairingId,
    required String clientName,
  }) async {
    await _call('approveRequest', device, adminUser, adminPassword,
        fields: {'pin': pin, 'pairingId': pairingId, 'clientName': clientName});
  }

  Future<Map<String, dynamic>> _call(
    String operation,
    Device device,
    String user,
    String password, {
    Map<String, Object?> fields = const {},
    void Function(PairingProgress)? onProgress,
  }) async {
    final request = jsonEncode({
      'version': 1,
      'operation': operation,
      'target': {
        'id': device.id,
        'name': device.name,
        'address': device.meshAddress,
        'port': device.sunshinePort,
        'webPort': device.webPort,
        'app': device.appName,
        'appId': device.appId,
        'hostUuid': device.hostUuid,
      },
      'user': user,
      'password': password,
      ...fields,
    });
    try {
      await for (final line
          in _exchange(request).timeout(const Duration(minutes: 4))) {
        final reply = jsonDecode(line) as Map<String, dynamic>;
        if (reply['version'] != 1) throw const FormatException();
        switch (reply['event']) {
          case 'progress' when operation == 'pair':
            onProgress?.call(PairingProgress(
              PairingPhase.values.byName(reply['phase'] as String),
              reply['message'] as String,
              pin: reply['pin'] as String?,
              requestName: reply['requestName'] as String?,
            ));
          case 'store' when operation == 'pair':
            await _writeSecret(
                device.id, reply['field'] as String, reply['value'] as String);
          case 'result':
            return reply;
          case 'error':
            throw PairingFailure(reply['message'] as String);
          default:
            throw const FormatException();
        }
      }
    } on TimeoutException {
      throw const PairingFailure('等待配对组件响应超时，请重试。');
    } on PairingFailure {
      rethrow;
    } catch (_) {
      // Keep parser/storage/platform errors (which may contain secret content)
      // out of the UI and logs.
      throw const PairingFailure('配对组件通信失败，请重试或重新安装。');
    }
    throw const PairingFailure('配对组件已退出，请重试。');
  }

  Future<void> _writeSecret(String deviceId, String field, String value) =>
      switch (field) {
        'clientCertPem' => _secureStore.writeClientCertPem(value),
        'clientKeyPem' => _secureStore.writeClientKeyPem(value),
        'clientKeyJson' => _secureStore.writeClientKeyJson(value),
        'uniqueId' => _secureStore.writeUniqueId(value),
        'sunshineUser' => _secureStore.writeSunshineUser(deviceId, value),
        'serverCertHex' => _secureStore.writeServerCertHex(deviceId, value),
        _ => throw const FormatException(),
      };

  static Stream<String> _platformExchange(String request) async* {
    if (Platform.isAndroid) {
      yield* _AndroidPairingTransport.exchange(request);
      return;
    }
    if (!Platform.isWindows) {
      throw const PairingFailure('当前系统不支持配对组件。');
    }
    final directory = File(Platform.resolvedExecutable).parent.path;
    yield* exchangeWithPairingExecutable(
        '$directory\\lulu_pairing_worker.exe', request);
  }
}

/// Anonymous pipes only. The process command line has no credentials.
Stream<String> exchangeWithPairingExecutable(
    String executable, String request) async* {
  if (!await File(executable).exists()) {
    throw const PairingFailure('找不到配对组件，请重新安装 LULU。');
  }
  final worker = await Process.start(executable, const [], runInShell: false);
  unawaited(worker.stderr.drain<void>());
  try {
    worker.stdin.add(utf8.encode('$request\n'));
    await worker.stdin.close();
    yield* worker.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
  } finally {
    worker.kill();
    await worker.exitCode;
  }
}

class _AndroidPairingTransport {
  static const _channel = MethodChannel('lulu.remote/pairing_worker');
  static final _requests = <int, StreamController<String>>{};
  static int _nextId = 0;
  static bool _initialized = false;

  static Stream<String> exchange(String request) async* {
    if (!_initialized) {
      _channel.setMethodCallHandler(_onMessage);
      _initialized = true;
    }
    final id = ++_nextId;
    final replies = StreamController<String>();
    _requests[id] = replies;
    try {
      await _channel
          .invokeMethod<void>('start', {'id': id, 'request': request});
      yield* replies.stream;
    } on PlatformException catch (error) {
      if (error.code == 'worker_unavailable') {
        throw const PairingFailure('请安装同一版本的 LULU Android 配对组件，然后重试。');
      }
      rethrow;
    } finally {
      _requests.remove(id);
      unawaited(replies.close());
      await _channel.invokeMethod<void>('stop', {'id': id});
    }
  }

  static Future<void> _onMessage(MethodCall call) async {
    final arguments = call.arguments as Map<dynamic, dynamic>;
    final replies = _requests[arguments['id']];
    if (replies == null || replies.isClosed) return;
    switch (call.method) {
      case 'reply':
        replies.add(arguments['reply'] as String);
      case 'finished':
        unawaited(replies.close());
    }
  }
}
