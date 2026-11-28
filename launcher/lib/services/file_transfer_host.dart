import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_transfer_service.dart';
import 'mesh_status_service.dart';
import 'power_service.dart';
import 'secure_store.dart';
import 'wake_on_lan.dart';
import 'wake_relay_service.dart';

bool isPrivateTransferAddress(String address) {
  final ip = InternetAddress.tryParse(address);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final bytes = ip.rawAddress;
  return bytes[0] == 10 ||
      bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
      bytes[0] == 192 && bytes[1] == 168 ||
      bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
}

class FileTransferHost {
  FileTransferHost._();

  static final instance = FileTransferHost._();
  static const _enabledKey = 'qg_file_transfer_enabled';
  static const _folderKey = 'qg_file_transfer_folder';
  static const _channel = MethodChannel('lulu/host_tray');
  final _secureStore = SecureStore();
  final _listeners = <String, HttpServer>{};
  FileTransferServer? _handler;
  Future<void> _fileCleanup = Future<void>.value();
  PowerServer? _power;
  WakeRelayServer? _wakeRelay;
  Future<String>? _readingWakeRelayCode;
  static const _wakeTargetsKey = 'qg_wake_targets';
  Future<String>? _readingCode;
  int _settingsGeneration = 0;
  Timer? _timer;
  Future<void> _updates = Future<void>.value();

  Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? false;

  Future<String> directoryPath() async {
    final prefs = await SharedPreferences.getInstance();
    final selected = prefs.getString(_folderKey);
    if (selected != null) return selected;
    final desktop = await _channel.invokeMethod<String>('knownDesktop');
    if (desktop == null || desktop.isEmpty) {
      throw StateError('无法找到桌面。请选择接收文件夹。');
    }
    return '$desktop${Platform.pathSeparator}LULU 接收';
  }

  Future<String> code() =>
      _readingCode ??= _loadCode().whenComplete(() => _readingCode = null);

  Future<String> _loadCode() async {
    final code = await _secureStore.readHostTransferCode();
    if (code != null && validTransferCode(code)) return code;
    return _rotateCode();
  }

  Future<String> _rotateCode() async {
    final value = newTransferCode();
    await _secureStore.writeHostTransferCode(value);
    return value;
  }

  Future<String> rotateCode() async {
    if (_readingCode case final active?) await active;
    _settingsGeneration++;
    await _retireFileReceiver();
    final value = await _rotateCode();
    _settingsGeneration++;
    await refresh();
    return value;
  }

  Future<void> setEnabled(bool enabled) async {
    _settingsGeneration++;
    final cleanup = enabled ? null : _retireFileReceiver();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(_enabledKey, enabled)) {
        await prefs.reload();
        throw StateError('无法保存文件接收设置。');
      }
      _settingsGeneration++;
    } finally {
      await cleanup;
    }
    await refresh();
  }

  Future<void> setFolder(String path) async {
    _settingsGeneration++;
    final folder = Directory(path);
    if (!await folder.exists()) throw StateError('请选择可用的文件夹。');
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_folderKey, path)) {
      await prefs.reload();
      throw StateError('无法保存接收目录。');
    }
    await refresh();
  }

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
        const Duration(seconds: 15), (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> stop() async {
    _settingsGeneration++;
    _timer?.cancel();
    _timer = null;
    await _disableCurrent();
    await refresh();
  }

  Future<void> refresh() => _updates = _updates.then((_) => _refresh());

  Future<Set<String>> wakeTargets() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final value in prefs.getStringList(_wakeTargetsKey) ?? <String>[])
        if (WakeOnLan.normalizeMac(value) case final mac?) mac,
    };
  }

  Future<void> setWakeTargets(Iterable<String> values) async {
    final targets = <String>{};
    for (final value in values) {
      final mac = WakeOnLan.normalizeMac(value);
      if (mac == null) throw const FormatException('请填写有效的有线网卡 MAC 地址。');
      targets.add(mac);
    }
    if (targets.length > 16) throw const FormatException('最多登记 16 台电脑。');
    _settingsGeneration++;
    _disableWakeRelay();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setStringList(_wakeTargetsKey, targets.toList())) {
      await prefs.reload();
      throw StateError('无法保存唤醒转发设置。');
    }
    _settingsGeneration++;
    await refresh();
  }

  Future<String> wakeRelayCode() => _readingWakeRelayCode ??=
      _loadWakeRelayCode().whenComplete(() => _readingWakeRelayCode = null);

  Future<String> _loadWakeRelayCode() async {
    final stored = await _secureStore.readHostWakeRelayCode();
    return stored != null && validTransferCode(stored)
        ? stored
        : _writeWakeRelayCode();
  }

  Future<String> _writeWakeRelayCode() async {
    final secret = newTransferCode();
    await _secureStore.writeHostWakeRelayCode(secret);
    return secret;
  }

  Future<String> rotateWakeRelayCode() async {
    if (_readingWakeRelayCode case final active?) await active;
    _settingsGeneration++;
    _disableWakeRelay();
    final secret = await _writeWakeRelayCode();
    _settingsGeneration++;
    await refresh();
    return secret;
  }

  void _disableWakeRelay() {
    _wakeRelay?.active = false;
    _wakeRelay = null;
  }

  Future<void> _retireFileReceiver() {
    if (_handler case final handler?) {
      _handler = null;
      _fileCleanup = handler.disable();
    }
    return _fileCleanup;
  }

  Future<void> setPowerEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _disablePower();
    await PowerAccess.instance.setEnabled(enabled);
    _settingsGeneration++;
    await refresh();
  }

  Future<String> rotatePowerCode() async {
    _settingsGeneration++;
    _disablePower();
    final code = await PowerAccess.instance.rotate();
    _settingsGeneration++;
    await refresh();
    return code;
  }

  void _disablePower() {
    _power?.enabled = false;
    _power = null;
  }

  Future<void> _disableCurrent() async {
    _disablePower();
    _disableWakeRelay();
    await _retireFileReceiver();
    final listeners = _listeners.values.toList();
    _listeners.clear();
    for (final listener in listeners) {
      await listener.close(force: true);
    }
  }

  Future<void> _refresh() async {
    final generation = _settingsGeneration;
    try {
      final fileEnabled = await isEnabled();
      final powerEnabled = await PowerAccess.instance.isEnabled();
      final targets = await wakeTargets();
      if (generation != _settingsGeneration) return;
      if (_timer == null ||
          !(fileEnabled || powerEnabled || targets.isNotEmpty)) {
        await _disableCurrent();
        return;
      }
      final path = fileEnabled ? await directoryPath() : null;
      final secret = fileEnabled ? await code() : null;
      final powerSecret =
          powerEnabled ? await PowerAccess.instance.code() : null;
      final wakeSecret = targets.isEmpty ? null : await wakeRelayCode();
      final addresses = (await MeshStatusService().localAddresses())
          .where((entry) =>
              entry.network != null && isPrivateTransferAddress(entry.address))
          .map((entry) => entry.address)
          .toSet();
      if (_timer == null || generation != _settingsGeneration) return;
      final previous = _handler;
      if (secret == null || path == null) {
        await _retireFileReceiver();
        if (_timer == null || generation != _settingsGeneration) return;
      } else if (previous == null ||
          previous.code != secret ||
          previous.receiveDirectory.path != path) {
        await _retireFileReceiver();
        if (_timer == null || generation != _settingsGeneration) return;
        _handler =
            FileTransferServer(code: secret, receiveDirectory: Directory(path));
      }
      if (powerSecret == null) {
        _disablePower();
      } else if (_power?.code != powerSecret) {
        _disablePower();
        _power = PowerServer(code: powerSecret, run: PowerServer.runOnWindows);
      }
      if (wakeSecret == null) {
        _disableWakeRelay();
      } else {
        if (_wakeRelay?.code != wakeSecret) {
          _disableWakeRelay();
          _wakeRelay =
              WakeRelayServer(code: wakeSecret, sendWake: WakeOnLan.send);
        }
        _wakeRelay!.wakeTargets = targets;
      }
      final expired = _listeners.keys
          .where((address) => !addresses.contains(address))
          .toList();
      for (final address in expired) {
        await _listeners.remove(address)?.close(force: true);
      }
      for (final address in addresses.difference(_listeners.keys.toSet())) {
        try {
          final listener = await HttpServer.bind(address, fileTransferPort);
          if (_timer == null || generation != _settingsGeneration) {
            await listener.close(force: true);
            continue;
          }
          listener.idleTimeout = const Duration(seconds: 20);
          _listeners[address] = listener;
          listener.listen(_dispatch, onError: (Object _) {});
        } on SocketException {
          // The mesh adapter may still be starting. Retry on the next refresh.
        }
      }
    } on Exception {
      await _disableCurrent();
    } on StateError {
      await _disableCurrent();
    }
  }

  void _dispatch(HttpRequest request) {
    final remote = request.connectionInfo?.remoteAddress.address;
    if (remote != null && isPrivateTransferAddress(remote)) {
      if (PowerServer.handles(request.uri.path)) {
        if (_power case final power?) {
          unawaited(power.handle(request));
          return;
        }
      } else if (WakeRelayServer.handles(request.uri.path)) {
        if (_wakeRelay case final relay?) {
          unawaited(relay.handle(request));
          return;
        }
      } else if (_handler case final files?) {
        unawaited(files.handle(request));
        return;
      }
    }
    request.response.statusCode = HttpStatus.forbidden;
    unawaited(request.response.close());
  }
}
