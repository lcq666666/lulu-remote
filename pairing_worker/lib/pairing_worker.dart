// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/device.dart';
import 'src/pairing_errors.dart';
import 'src/pairing_memory.dart';
import 'src/pairing_service.dart';
import 'src/sunshine_pin_api.dart';

/// Handles one versioned request. Replies go only to the private IPC transport.
Future<void> runPairingRequest(String line, void Function(String) send) async {
  void emit(String event, [Map<String, Object?> data = const {}]) =>
      send(jsonEncode({'version': 1, 'event': event, ...data}));

  try {
    final request = jsonDecode(line) as Map<String, dynamic>;
    if (request['version'] != 1) throw const FormatException();
    if (request['operation'] == 'ping') {
      emit('result');
      return;
    }
    final target = request['target'] as Map<String, dynamic>;
    final device = Device(
      id: target['id'] as String,
      name: target['name'] as String,
      meshAddress: target['address'] as String,
      sunshinePort: target['port'] as int,
      webPort: target['webPort'] as int,
      appName: target['app'] as String,
      appId: target['appId'] as int?,
      hostUuid: target['hostUuid'] as String?,
    );
    final user = request['user'] as String;
    final password = request['password'] as String;
    final api = SunshinePinApi();
    switch (request['operation']) {
      case 'pair':
        final identity = request['identity'] as Map<String, dynamic>;
        final memory = PairingMemory(
          certPem: identity['clientCertPem'] as String?,
          keyPem: identity['clientKeyPem'] as String?,
          keyJson: identity['clientKeyJson'] as String?,
          uniqueId: identity['uniqueId'] as String?,
          onWrite: (field, value) =>
              emit('store', {'field': field, 'value': value}),
        );
        final result =
            await PairingService(secureStore: memory, pinApi: api).pair(
          device: device,
          adminUser: user,
          adminPassword: password,
          onProgress: (progress) => emit('progress', {
            'phase': progress.phase.name,
            'message': progress.message,
            'pin': progress.pin,
            'requestName': progress.requestName,
          }),
        );
        emit('result',
            {'appId': result.device.appId, 'hostUuid': result.device.hostUuid});
      case 'verifyAccount':
        await api.verifyAccount(
            device: device, adminUser: user, adminPassword: password);
        emit('result');
      case 'listPairings':
        final pending = await api.listPairings(device, user, password);
        emit('result', {
          'requests': [
            for (final entry in pending)
              {'id': entry.id, 'name': entry.name, 'address': entry.address},
          ],
        });
      case 'approveRequest':
        await api.approveRequest(
          device: device,
          pin: request['pin'] as String,
          adminUser: user,
          adminPassword: password,
          pairingId: request['pairingId'] as String,
          clientName: request['clientName'] as String,
        );
        emit('result');
      default:
        throw const FormatException();
    }
  } on PairingException catch (error) {
    emit('error', {'message': error.message});
  } on HttpException catch (error) {
    emit('error', {'message': error.message});
  } on TimeoutException {
    emit('error', {'message': '等待对方响应超时。请确认被控电脑在线，再重试当前步骤。'});
  } on SocketException {
    emit('error', {'message': '连接中断。请确认两台电脑的网络仍然连接，再重试。'});
  } catch (_) {
    emit('error', {'message': '这一步未能完成。请重试，或在连接设置里检查组件。'});
  }
}
