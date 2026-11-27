import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_transfer_service.dart';
import 'host_hardware.dart';
import 'host_tools_service.dart';
import 'remote_command.dart';
import 'mesh_status_service.dart';
import 'power_service.dart';
import 'privacy_screen_service.dart';
import 'secure_store.dart';
import 'wake_on_lan.dart';

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
  HostToolsServer? _tools;
  Future<String>? _readingToolsCode;
  static const _clipboardSyncKey = 'qg_clipboard_sync_enabled';
  static const _clipboardKey = 'qg_clipboard_enabled';
  static const _diagnosticsKey = 'qg_diagnostics_enabled';
  static const _commandKey = 'qg_commands_enabled';
  static const _wakeTargetsKey = 'qg_wake_targets';
  static const _hardwareKey = 'qg_hardware_enabled';
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

  Future<void> setPowerEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _disablePower();
    await PowerAccess.instance.setEnabled(enabled);
    await refresh();
  }

  Future<String> rotatePowerCode() async {
    _settingsGeneration++;
    _disablePower();
    final code = await PowerAccess.instance.rotate();
    await refresh();
    return code;
  }

  Future<bool> clipboardEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_clipboardKey) ?? false;

  Future<bool> clipboardSyncEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_clipboardSyncKey) ??
      false;

  Future<void> setClipboardSyncEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _tools?.clipboardSyncEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_clipboardSyncKey, enabled)) {
      await prefs.reload();
      throw StateError('无法保存剪贴板同步设置。');
    }
    await refresh();
  }

  Future<void> setClipboardEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _disableTools();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_clipboardKey, enabled)) {
      await prefs.reload();
      throw StateError('无法保存剪贴板设置。');
    }
    await refresh();
  }

  Future<bool> diagnosticsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_diagnosticsKey) ?? false;

  Future<void> setDiagnosticsEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _tools?.diagnosticsEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_diagnosticsKey, enabled)) {
      await prefs.reload();
      throw StateError('无法保存连接诊断设置。');
    }
    await refresh();
  }

  Future<ApprovedWindowsCommand?> approvedWindowsCommand() async =>
      ApprovedWindowsCommand.decode(
          await _secureStore.readApprovedWindowsCommand());

  Future<void> saveApprovedWindowsCommand(ApprovedWindowsCommand? command) =>
      _secureStore.writeApprovedWindowsCommand(command?.encode());

  Future<String> _executeWindowsCommand(RemoteCommand query) async {
    final server = _tools;
    final preset =
        query == RemoteCommand.approved ? await approvedWindowsCommand() : null;
    if (!identical(_tools, server) || server?.commandsEnabled != true) {
      return '被控端已关闭远程命令。';
    }
    return RemoteCommand.runOnWindows(query, approved: preset);
  }

  Future<bool> commandsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_commandKey) ?? false;

  Future<void> setCommandsEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _tools?.commandsEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_commandKey, enabled)) {
      await prefs.reload();
      throw StateError('无法保存远程命令设置。');
    }
    await refresh();
  }

  Future<bool> hardwareEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_hardwareKey) ?? false;

  Future<void> setHardwareEnabled(bool enabled) async {
    _settingsGeneration++;
    if (!enabled) _tools?.hardwareEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_hardwareKey, enabled)) {
      await prefs.reload();
      throw StateError('无法保存硬件信息设置。');
    }
    await refresh();
  }

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
    _tools?.wakeTargets = const {};
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setStringList(_wakeTargetsKey, targets.toList())) {
      await prefs.reload();
      throw StateError('无法保存唤醒转发设置。');
    }
    await refresh();
  }

  Future<String> _diagnostics() async {
    var listening = true;
    try {
      await MeshStatusService().verifyLocalHost();
    } on StateError {
      listening = false;
    }
    return '电脑名称：${Platform.localHostname}\n远程服务：${listening ? '有应答' : '未就绪'}';
  }

  Future<String> toolsCode() => _readingToolsCode ??=
      _loadToolsCode().whenComplete(() => _readingToolsCode = null);

  Future<String> _loadToolsCode() async {
    final value = await _secureStore.readHostToolsCode();
    return value != null && validTransferCode(value)
        ? value
        : _writeToolsCode();
  }

  Future<String> _writeToolsCode() async {
    final value = newTransferCode();
    await _secureStore.writeHostToolsCode(value);
    return value;
  }

  Future<String> rotateToolsCode() async {
    if (_readingToolsCode case final active?) await active;
    _settingsGeneration++;
    _disableTools();
    final code = await _writeToolsCode();
    await refresh();
    return code;
  }

  void _disableTools() {
    _tools?.active = false;
    _tools = null;
  }

  void _disablePower() {
    _power?.enabled = false;
    _power = null;
  }

  Future<void> _disableCurrent() async {
    _disablePower();
    _disableTools();
    await _closeListeners();
  }

  Future<void> _retireFileReceiver() {
    if (_handler case final handler?) {
      _handler = null;
      _fileCleanup = handler.disable();
    }
    return _fileCleanup;
  }

  Future<void> _closeListeners() async {
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
      final clipboard = await clipboardEnabled();
      final clipboardSync = await clipboardSyncEnabled();
      final diagnostics = await diagnosticsEnabled();
      final commands = await commandsEnabled();
      final hardware = await hardwareEnabled();
      final targets = await wakeTargets();
      if (_timer == null ||
          !(fileEnabled ||
              powerEnabled ||
              clipboard ||
              diagnostics ||
              commands ||
              hardware ||
              targets.isNotEmpty)) {
        await _disableCurrent();
        return;
      }
      final path = fileEnabled ? await directoryPath() : null;
      final secret = fileEnabled ? await code() : null;
      final powerSecret =
          powerEnabled ? await PowerAccess.instance.code() : null;
      final toolsSecret =
          clipboard || diagnostics || commands || hardware || targets.isNotEmpty
              ? await toolsCode()
              : null;
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
      if (toolsSecret == null) {
        _disableTools();
      } else if (_tools?.code != toolsSecret) {
        _disableTools();
        _tools = HostToolsServer(
          code: toolsSecret,
          readDiagnostics: _diagnostics,
          runCommand: _executeWindowsCommand,
          readHardware: HostHardware.readWindows,
          sendWake: WakeOnLan.send,
          streaming: () =>
              PrivacyScreenService.instance.streaming.value == true,
          readClipboard: () async =>
              (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '',
          writeClipboard: (text) =>
              Clipboard.setData(ClipboardData(text: text)),
        );
      }
      _tools
        ?..clipboardEnabled = clipboard
        ..clipboardSyncEnabled = clipboardSync
        ..diagnosticsEnabled = diagnostics
        ..commandsEnabled = commands
        ..hardwareEnabled = hardware
        ..wakeTargets = targets;
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
      } else if (HostToolsServer.handles(request.uri.path)) {
        if (_tools case final tools?) {
          unawaited(tools.handle(request));
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
