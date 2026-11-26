import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../models/quality_preset.dart';
import '../services/device_store.dart';
import '../services/mesh_status_service.dart';
import '../services/moonlight_launcher.dart';
import '../services/secure_store.dart';
import '../widgets/device_card.dart';
import 'add_device_screen.dart';
import 'pairing_screen.dart';
import 'setup_checklist_screen.dart';

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
  String? _localMeshAddress;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final devices = await _deviceStore.load();
    final local = await _mesh.localMeshAddress();
    setState(() {
      _devices = devices;
      _localMeshAddress = local;
      _loading = false;
    });
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final next = <String, HostStatus>{};
    for (final device in _devices) {
      next[device.id] = await _mesh.check(device);
    }
    if (mounted) setState(() => _status = next);
  }

  Future<void> _connect(Device device) async {
    if (!device.paired) {
      await _openPairing(device);
      return;
    }
    setState(() => _connectingId = device.id);
    try {
      if (Platform.isWindows) {
        await _launcher.streamWindows(device, _preset);
        _snack('已拉起 Moonlight，正在连接 ${device.name}…');
      } else if (Platform.isAndroid) {
        await _connectAndroid(device);
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

  /// Android: Game Intent with LULU's own cert first (unverified
  /// prototype — see MainActivity.kt); fall back to ShortcutTrampoline
  /// when the device was paired inside Moonlight itself.
  Future<void> _connectAndroid(Device device) async {
    final serverCertHex =
        await _secureStore.readServerCertHex(device.id);
    if (serverCertHex == null || device.appId == null) {
      // No LULU cert on file — this device was paired the old way.
      final ok = await _launcher.launchShortcut(device);
      _snack(ok ? '已拉起 Moonlight。' : '拉起 Moonlight 失败，请检查它是否已安装。');
      return;
    }
    final serverCertDer = _hexToBytes(serverCertHex);
    try {
      final ok = await _launcher.streamAndroid(
        device,
        useOwnCert: true,
        serverCertDer: serverCertDer,
      );
      _snack(ok ? '已拉起 Moonlight。' : 'Game Intent 没有拉起，正在试备用方式…');
      if (!ok) await _launcher.launchShortcut(device);
    } on MoonlightLaunchException {
      // Game Intent path failed — try the ShortcutTrampoline fallback.
      final ok = await _launcher.launchShortcut(device);
      _snack(ok ? '已用备用方式拉起 Moonlight。' : '两种拉起方式都失败了，见 BUILD.md 第 4 条。');
    }
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  Future<void> _openPairing(Device device) async {
    final updated = await Navigator.of(context).push<Device>(
      MaterialPageRoute(builder: (_) => PairingScreen(device: device)),
    );
    if (updated != null) {
      setState(() {
        _devices = _devices
            .map((d) => d.id == updated.id ? updated : d)
            .toList();
      });
      await _deviceStore.save(_devices);
      await _refreshStatus();
    }
  }

  Future<void> _openAddDevice() async {
    if (_devices.length >= DeviceStore.maxDevices) {
      _snack('v1 只支持 ${DeviceStore.maxDevices} 台电脑。');
      return;
    }
    final device = await Navigator.of(context).push<Device>(
      MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
    );
    if (device != null) {
      setState(() => _devices = [..._devices, device]);
      await _deviceStore.save(_devices);
      await _refreshStatus();
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
            icon: const Icon(Icons.checklist),
            tooltip: '设置检查清单',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SetupChecklistScreen(),
                ),
              );
            },
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
          : Column(
              children: [
                _PresetBar(
                  selected: _preset,
                  onSelected: (p) => setState(() => _preset = p),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        children: [
                          const Text(
                            '我的电脑',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: LuluTheme.text,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${_devices.length} 台设备',
                            style: const TextStyle(color: LuluTheme.muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      for (final device in _devices) ...[
                        DeviceCard(
                          device: device,
                          preset: _preset,
                          status: _status[device.id],
                          connecting: _connectingId == device.id,
                          onConnect: () => _connect(device),
                          onPair: () => _openPairing(device),
                        ),
                        const SizedBox(height: 12),
                      ],
                      OutlinedButton.icon(
                        onPressed: _openAddDevice,
                        icon: const Icon(Icons.add),
                        label: const Text('添加电脑（填组网地址即可）'),
                      ),
                    ],
                  ),
                ),
                _Footer(localMeshAddress: _localMeshAddress),
              ],
            ),
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
                    color: isSelected
                        ? const Color(0xFF06231B)
                        : LuluTheme.text,
                  ),
                  onSelected: (_) => onSelected(preset),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.localMeshAddress});
  final String? localMeshAddress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: LuluTheme.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.circle, size: 10, color: LuluTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '组网正常 · Tailscale 已连接 · 本机地址 ${localMeshAddress ?? '未知（演示）'}',
              style: const TextStyle(color: LuluTheme.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
