import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../models/device.dart';
import '../models/quality_preset.dart';
import '../services/component_installer.dart';
import '../services/device_store.dart';
import '../services/mesh_status_service.dart';
import '../services/moonlight_launcher.dart';
import '../services/secure_store.dart';
import '../widgets/device_card.dart';
import 'add_device_screen.dart';
import 'pairing_screen.dart';
import 'setup_checklist_screen.dart';
import 'this_computer_screen.dart';

/// Home: device list (2 hosts), quality presets, connect, mesh footer.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _deviceStore = DeviceStore();
  final _mesh = MeshStatusService();
  final _launcher = MoonlightLauncher();
  final _secureStore = SecureStore();

  List<Device> _devices = [];
  Map<String, HostStatus> _status = {};
  QualityPreset _preset = QualityPreset.office1080;
  String? _connectingId;
  bool _loading = true;
  bool _saving = false;
  Timer? _statusTimer;
  int _statusRefresh = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final devices = await _deviceStore.load();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loading = false;
    });
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    if (_devices.isEmpty || _connectingId != null) return;
    final devices = _devices;
    final refresh = ++_statusRefresh;
    final entries = await Future.wait(devices.map((device) async {
      return MapEntry(device.id, await _mesh.check(device));
    }));
    if (mounted && identical(devices, _devices) && refresh == _statusRefresh) {
      setState(() => _status = Map.fromEntries(entries));
    }
  }

  Future<void> _checkConnection(Device device) async {
    ++_statusRefresh;
    var status = await _mesh.check(device);
    if (status != HostStatus.online && mounted) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      status = await _mesh.check(device);
    }
    if (!mounted) return;
    setState(() => _status[device.id] = status);
    if (status != HostStatus.online) {
      throw MoonlightLaunchException(
        '暂时连不上「${device.name}」。请确认对方电脑已开机、远程控制已开启，并检查连接地址。',
      );
    }
  }

  Future<void> _connect(Device device, {bool androidShortcut = false}) async {
    if (_connectingId != null || _saving) return;
    if (!device.paired) {
      await _openPairing(device);
      return;
    }
    setState(() => _connectingId = device.id);
    try {
      if (Platform.isWindows) {
        await _connectWindows(device);
      } else if (Platform.isAndroid) {
        await _connectAndroid(device, shortcut: androidShortcut);
      } else {
        _snack('这个平台还不支持一键连接，请用 Windows 或安卓。');
      }
    } on MoonlightNotInstalledException catch (e) {
      _snack(e.message);
    } on NotPairedException catch (e) {
      _snack(e.message);
    } on MoonlightLaunchException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('连接失败：$e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _connectWindows(Device device) async {
    await _checkConnection(device);
    if (!mounted) return;
    if (await _launcher.findMoonlightQt() == null) {
      _snack('首次连接，正在准备连接组件…');
      final result = await ComponentInstaller().prepareWindowsController();
      if (await _launcher.findMoonlightQt() == null) {
        throw MoonlightLaunchException(result);
      }
    }
    if (!mounted) return;
    final process = await _launcher.streamWindows(device, _preset);
    final error = StringBuffer();
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
      if (error.length < 8192) error.write(chunk);
    });
    unawaited(process.stdout.drain<void>());
    final exit = process.exitCode;
    final earlyExit = await exit.then<int?>((code) => code).timeout(
          const Duration(seconds: 3),
          onTimeout: () => null,
        );
    if (earlyExit != null) {
      throw MoonlightLaunchException(
          await _windowsExitMessage(earlyExit, stderr, error));
    }
    unawaited(exit.then((code) async {
      if (code != 0) _snack(await _windowsExitMessage(code, stderr, error));
    }));
  }

  Future<String> _windowsExitMessage(
    int code,
    Future<void> stderr,
    StringBuffer error,
  ) async {
    await stderr;
    final message = error.toString().trim();
    return message.isEmpty ? 'Moonlight 已退出（退出码 $code）。' : message;
  }

  Future<void> _disconnectWindows(Device device) async {
    if (_connectingId != null || _saving) return;
    setState(() => _connectingId = device.id);
    try {
      await _launcher.quitWindows(device);
      _snack('已请求断开 ${device.name}。');
    } catch (e) {
      _snack('断开连接失败：$e');
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _connectAndroid(Device device, {bool shortcut = false}) async {
    await _checkConnection(device);
    if (!mounted) return;
    final serverCertHex = await _secureStore.readServerCertHex(device.id);
    var opened = false;
    if (!shortcut &&
        serverCertHex != null &&
        device.hostUuid != null &&
        device.appId != null) {
      try {
        opened = await _launcher.streamAndroid(
          device,
          useOwnCert: true,
          serverCertDer: _hexToBytes(serverCertHex),
        );
      } on MoonlightLaunchException {
        // Try the shortcut for hosts already paired inside Moonlight.
      }
    }
    if (!opened && device.hostUuid != null && device.appId != null) {
      try {
        opened = await _launcher.launchShortcut(device);
      } on MoonlightLaunchException {
        // Show the same recovery instructions for either launch path.
      }
    }
    if (!mounted) return;
    if (opened) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('已请求打开 Moonlight，请在 Moonlight 中确认是否开始串流。'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: '连接失败帮助',
          onPressed: () => _showAndroidHelp(device),
        ),
      ));
    } else {
      unawaited(_showAndroidHelp(device));
    }
  }

  Future<void> _showAndroidHelp(Device device) async {
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Moonlight 退出或连接失败'),
        content: const Text('安卓端需要在 Moonlight 里先配对一次，再回 LULU 点连接。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'store'),
            child: const Text('Moonlight 商店页'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'shortcut'),
            child: const Text('已在 Moonlight 配对，重试'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'shortcut') {
      await _connect(device, androidShortcut: true);
    } else if (action == 'store') {
      await _openMoonlightStore();
    }
  }

  Future<void> _openMoonlightStore() async {
    try {
      final opened = await launchUrl(
        Uri.parse(
            'https://play.google.com/store/apps/details?id=com.limelight'),
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;
    } catch (_) {
      // Keep the manual opening instructions available.
    }
    _snack('无法打开商店，请从手机应用列表打开 Moonlight。');
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  Future<void> _openPairing(Device device) async {
    if (_saving || _connectingId != null) return;
    final updated = await Navigator.of(context).push<Device>(
      MaterialPageRoute(builder: (_) => PairingScreen(device: device)),
    );
    if (mounted && updated != null) {
      await _saveDeviceChange(() => _deviceStore.updateDevice(updated));
    }
  }

  Future<void> _openAddDevice([Device? existing]) async {
    if (_saving || _connectingId != null) return;
    final device = await Navigator.of(context).push<Device>(
      MaterialPageRoute(builder: (_) => AddDeviceScreen(device: existing)),
    );
    if (!mounted || device == null) return;
    await _saveDeviceChange(() async {
      if (existing == null) {
        await _deviceStore.save([..._devices, device]);
      } else {
        if (existing.meshAddress != device.meshAddress ||
            existing.sunshinePort != device.sunshinePort ||
            existing.webPort != device.webPort) {
          await _secureStore.deleteDeviceSecrets(device.id);
        }
        await _deviceStore.updateDevice(device);
      }
    });
  }

  Future<void> _deleteDevice(Device device) async {
    if (_saving || _connectingId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${device.name}？'),
        content: const Text('这会移除这台电脑及其本机保存的配对信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _saveDeviceChange(() async {
      await _secureStore.deleteDeviceSecrets(device.id);
      await _deviceStore.deleteDevice(device.id);
    });
  }

  Future<void> _saveDeviceChange(Future<void> Function() save) async {
    setState(() => _saving = true);
    try {
      await save();
      final devices = await _deviceStore.load();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _status = {};
      });
      await _refreshStatus();
    } catch (e) {
      _snack('更新电脑列表失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _openThisComputer() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const ThisComputerScreen(),
    ));
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const SetupChecklistScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'LULU 远程',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '连接设置',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
            onPressed: _refreshStatus,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, constraints) {
              final wide = Platform.isWindows && constraints.maxWidth >= 760;
              final content = ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      const Expanded(
                          child: Text(
                        '连接电脑',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: LuluTheme.text,
                        ),
                      )),
                      ElevatedButton.icon(
                        onPressed: _saving ? null : _openAddDevice,
                        icon: const Icon(Icons.add),
                        label: const Text('添加电脑'),
                      ),
                    ],
                  ),
                  if (Platform.isWindows && !wide)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openThisComputer,
                        icon: const Icon(Icons.desktop_windows_outlined),
                        label: const Text('让别人连接我'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (_devices.isEmpty)
                    const ListTile(
                      leading: Icon(Icons.desktop_windows_outlined),
                      title: Text('还没有添加电脑'),
                    ),
                  for (final device in _devices) ...[
                    DeviceCard(
                      device: device,
                      status: _status[device.id],
                      connecting: _connectingId == device.id || _saving,
                      onConnect: () => _connect(device),
                      onEdit: _saving ? null : () => _openAddDevice(device),
                      onDelete: _saving ? null : () => _deleteDevice(device),
                      onDisconnect: Platform.isWindows && device.paired
                          ? () => _disconnectWindows(device)
                          : null,
                      onAndroidHelp: Platform.isAndroid && device.paired
                          ? () => _showAndroidHelp(device)
                          : null,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (Platform.isWindows && _devices.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tune),
                      title: const Text('连接画质'),
                      subtitle: Text(_preset.summary),
                      children: [
                        _PresetBar(
                          selected: _preset,
                          onSelected: (p) => setState(() => _preset = p),
                        ),
                      ],
                    ),
                ],
              );
              if (!wide) return content;
              return Row(
                children: [
                  SizedBox(
                    width: 225,
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        const ListTile(
                          selected: true,
                          leading: Icon(Icons.devices_outlined),
                          title: Text('连接电脑'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.desktop_windows_outlined),
                          title: const Text('让别人连接我'),
                          onTap: _openThisComputer,
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              );
            }),
    );
  }
}

class _PresetBar extends StatelessWidget {
  const _PresetBar({required this.selected, required this.onSelected});
  final QualityPreset selected;
  final ValueChanged<QualityPreset> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          const Text('画质预设', style: TextStyle(color: LuluTheme.muted)),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 8,
              children: QualityPreset.all.map((preset) {
                final isSelected = preset.id == selected.id;
                return ChoiceChip(
                  label: Text(preset.label),
                  selected: isSelected,
                  selectedColor: LuluTheme.accent,
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : LuluTheme.text,
                  ),
                  onSelected: (_) => onSelected(preset.withFps(selected.fps)),
                );
              }).toList(),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: selected.fps,
            items: [
              for (final fps in [30, 60, 75, 90, 120, 144])
                DropdownMenuItem(value: fps, child: Text('$fps FPS')),
            ],
            onChanged: (fps) {
              if (fps != null) onSelected(selected.withFps(fps));
            },
          ),
        ],
      ),
    );
  }
}
