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
import '../widgets/lulu_ui.dart';
import 'add_device_screen.dart';
import 'pairing_screen.dart';
import 'setup_checklist_screen.dart';
import 'this_computer_screen.dart';

enum _HomeTab { connect, host, settings }

typedef _HostCheck = ({HostStatus status, String detail, Duration elapsed});

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      required this.themeMode,
      required this.onThemeChanged,
      this.machineSuffix,
      this.onResetActivation});

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final String? machineSuffix;
  final VoidCallback? onResetActivation;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _deviceStore = DeviceStore();
  final _mesh = MeshStatusService();
  final _launcher = MoonlightLauncher();
  final _secureStore = SecureStore();

  List<Device> _devices = [];
  Map<String, _HostCheck> _status = {};
  QualityPreset _preset = QualityPreset.office1080;
  String? _connectingId;
  bool _loading = true;
  bool _saving = false;
  Timer? _statusTimer;
  int _statusRefresh = 0;
  _HomeTab _tab = _HomeTab.connect;
  bool _manualRefresh = false;

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
      return MapEntry(device.id, await _measureHostCheck(device));
    }));
    if (mounted && identical(devices, _devices) && refresh == _statusRefresh) {
      setState(() => _status = Map.fromEntries(entries));
    }
  }

  Future<_HostCheck> _measureHostCheck(Device device) async {
    final watch = Stopwatch()..start();
    final result = await _mesh.diagnose(device);
    return (
      status: result.status,
      detail: result.detail,
      elapsed: watch.elapsed
    );
  }

  Future<void> _checkConnection(Device device) async {
    ++_statusRefresh;
    var check = await _measureHostCheck(device);
    if (check.status != HostStatus.online && mounted) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      check = await _measureHostCheck(device);
    }
    if (!mounted) return;
    setState(() => _status[device.id] = check);
    if (check.status != HostStatus.online) {
      throw MoonlightLaunchException(
        '连不上「${device.name}」（${device.meshAddress}:${device.sunshinePort}）。${check.detail}',
      );
    }
  }

  Future<void> _connect(Device device, {bool androidShortcut = false}) async {
    if (_connectingId != null || _saving) return;
    if (!Platform.isWindows && !device.paired) {
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
    var client = await _launcher.findWindowsClient();
    if (!mounted) return;
    if (client == null) {
      _snack('正在准备 Windows 连接组件。如有管理员确认，请点「是」。');
      final result = await ComponentInstaller().prepareWindowsController();
      client = await _launcher.findWindowsClient();
      if (!mounted) return;
      if (client == null) throw MoonlightLaunchException(result);
    }

    // Old device cards may be paired only with LULU's client certificate.
    // Ask the exact Moonlight profile we will use for streaming every time.
    var apps = await client.listApps(device);
    if (!mounted) return;
    if (apps == null) {
      await _checkConnection(device);
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('首次连接 ${device.name}'),
          content: const Text(
            'LULU 会用已保存的地址打开 Moonlight 配对窗口。请在被控电脑上，将窗口显示的 PIN 填入 LULU 的托盘配对提醒，或在 Sunshine 管理页提交。配对窗口显示成功后，关闭它即可继续。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('打开配对窗口'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      await client.pair(device);
      if (!mounted) return;
      apps = await client.listApps(device);
      if (!mounted) return;
      if (apps == null) {
        await _checkConnection(device);
        throw const MoonlightLaunchException('配对还没完成。请重新连接，并在被控电脑上确认 PIN。');
      }
    }

    if (!device.paired) {
      final updated = device.copyWith(paired: true);
      await _deviceStore.updateDevice(updated);
      if (!mounted) return;
      setState(() => _devices = [
            for (final saved in _devices)
              if (saved.id == updated.id) updated else saved,
          ]);
    }
    if (!apps.any((app) => app.toLowerCase() == device.appName.toLowerCase())) {
      throw MoonlightLaunchException(
          '「${device.name}」未提供「${device.appName}」。请核对 Sunshine 的应用列表，或编辑此电脑的应用名。');
    }
    final process = await client.stream(device, _preset);
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
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
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
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final theme = LuluTheme.of(context);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Moonlight 退出或连接失败',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('${device.meshAddress}:${device.sunshinePort}',
                    style: LuluTheme.mono.copyWith(color: theme.muted)),
                const SizedBox(height: 8),
                Text(
                    '确认对方电脑已开启远程服务，两台设备使用同一局域网或组网。安卓端需要先在 Moonlight 中与对方配对，再返回 LULU 重试。',
                    style: TextStyle(color: theme.muted, fontSize: 13)),
                const SizedBox(height: 16),
                if (device.paired)
                  FilledButton(
                      onPressed: () => Navigator.pop(context, 'shortcut'),
                      child: const Text('已在 Moonlight 配对，重试')),
                OutlinedButton(
                    onPressed: () => Navigator.pop(context, 'settings'),
                    child: const Text('前往连接设置检测')),
                TextButton(
                    onPressed: () => Navigator.pop(context, 'store'),
                    child: const Text('Moonlight 商店页')),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (action == 'shortcut') {
      await _connect(device, androidShortcut: true);
    } else if (action == 'settings') {
      _selectTab(_HomeTab.settings);
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
    final updated = await _openDeviceForm(
        (dialog) => PairingScreen(device: device, dialog: dialog));
    if (mounted && updated != null) {
      await _saveDeviceChange(() => _deviceStore.updateDevice(updated));
    }
  }

  Future<void> _openAddDevice([Device? existing]) async {
    if (_saving || _connectingId != null) return;
    final device = await _openDeviceForm(
        (dialog) => AddDeviceScreen(device: existing, dialog: dialog));
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
    showLuluSnack(context, message);
  }

  Future<Device?> _openDeviceForm(Widget Function(bool dialog) builder) {
    if (Platform.isWindows) {
      return showDialog<Device>(
        context: context,
        barrierColor: Colors.black54,
        barrierDismissible: false,
        builder: (_) => builder(true),
      );
    }
    return Navigator.of(context).push<Device>(
      MaterialPageRoute(builder: (_) => builder(false)),
    );
  }

  Future<void> _refreshFromToolbar() async {
    setState(() => _manualRefresh = true);
    try {
      await _refreshStatus();
    } finally {
      if (mounted) setState(() => _manualRefresh = false);
    }
  }

  bool get _busy => _loading || _saving || _connectingId != null;

  void _selectTab(_HomeTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final windows = Platform.isWindows;
      final wide = windows && constraints.maxWidth >= 760;
      final theme = LuluTheme.of(context);
      final content = switch (_tab) {
        _HomeTab.connect => _connectionPage(windows),
        _HomeTab.host => const ThisComputerScreen(embedded: true),
        _HomeTab.settings => SetupChecklistScreen(
            embedded: true,
            showTitle: wide,
            preferences: _preferences(windows),
          ),
      };
      return Scaffold(
        appBar: wide
            ? null
            : AppBar(
                title: Text(switch (_tab) {
                  _HomeTab.connect => '强哥远程',
                  _HomeTab.host => '让别人连接我',
                  _HomeTab.settings => '连接设置',
                }),
                actions: _tab == _HomeTab.connect
                    ? [
                        _refreshButton(),
                        IconButton(
                            tooltip: '添加电脑',
                            onPressed: _busy ? null : _openAddDevice,
                            icon: const Icon(Icons.add, size: 23)),
                        const SizedBox(width: 8),
                      ]
                    : null,
              ),
        bottomNavigationBar: wide
            ? null
            : DecoratedBox(
                decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: theme.divider))),
                child: NavigationBar(
                  selectedIndex: windows
                      ? _tab.index
                      : (_tab == _HomeTab.settings ? 1 : 0),
                  onDestinationSelected: (index) => _selectTab(windows
                      ? _HomeTab.values[index]
                      : [_HomeTab.connect, _HomeTab.settings][index]),
                  destinations: [
                    const NavigationDestination(
                        icon: Icon(Icons.desktop_windows_outlined),
                        label: '连接电脑'),
                    if (windows)
                      const NavigationDestination(
                          icon: Icon(Icons.share_outlined), label: '让别人连接我'),
                    const NavigationDestination(
                        icon: Icon(Icons.settings_outlined), label: '连接设置'),
                  ],
                ),
              ),
        body: wide
            ? Row(children: [_sidebar(theme), Expanded(child: content)])
            : content,
      );
    });
  }

  Widget _sidebar(LuluTheme theme) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
          color: theme.sidebar,
          border: Border(right: BorderSide(color: theme.divider))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
            child: ListView(padding: const EdgeInsets.all(10), children: [
          _navEntry(_HomeTab.connect, Icons.desktop_windows_outlined, '连接电脑'),
          const SizedBox(height: 4),
          _navEntry(_HomeTab.host, Icons.share_outlined, '让别人连接我'),
        ])),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _navEntry(_HomeTab.settings, Icons.settings_outlined, '连接设置'),
            const SizedBox(height: 8),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _themeButtons()),
          ]),
        ),
      ]),
    );
  }

  Widget _navEntry(_HomeTab tab, IconData icon, String label) {
    final theme = LuluTheme.of(context);
    final active = tab == _tab;
    final color = active ? theme.text : theme.muted;
    return Semantics(
        selected: active,
        button: true,
        child: Material(
          color: active ? theme.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: () => _selectTab(tab),
            borderRadius: BorderRadius.circular(8),
            child: Stack(alignment: Alignment.centerLeft, children: [
              if (active)
                Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                        color: theme.accent,
                        borderRadius: BorderRadius.circular(4))),
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    Icon(icon, size: 17, color: color),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text(label,
                            style: TextStyle(fontSize: 14, color: color))),
                  ])),
            ]),
          ),
        ));
  }

  Widget _themeButtons({bool mobile = false}) {
    final theme = LuluTheme.of(context);
    return Wrap(spacing: 6, children: [
      for (final (mode, icon, label) in [
        (ThemeMode.light, Icons.light_mode_outlined, '浅色模式'),
        (ThemeMode.dark, Icons.dark_mode_outlined, '深色模式'),
      ])
        Semantics(
            selected: mode == widget.themeMode,
            child: IconButton(
              tooltip: label,
              onPressed: () => widget.onThemeChanged(mode),
              style: IconButton.styleFrom(
                foregroundColor:
                    mode == widget.themeMode ? theme.text : theme.muted,
                backgroundColor:
                    mode == widget.themeMode ? theme.selected : null,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
                minimumSize: Size.square(mobile ? 44 : 30),
                padding: EdgeInsets.zero,
                tapTargetSize: mobile
                    ? MaterialTapTargetSize.padded
                    : MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(icon, size: 17),
            )),
    ]);
  }

  Widget _refreshButton() => IconButton(
        tooltip: '刷新状态',
        onPressed: _busy || _manualRefresh ? null : _refreshFromToolbar,
        icon: _manualRefresh
            ? const SizedBox.square(
                dimension: 17, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh, size: 20),
      );

  Widget _connectionPage(bool windows) {
    final theme = LuluTheme.of(context);
    return SafeArea(
      top: false,
      bottom: windows,
      child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: windows ? 960 : double.infinity),
            child: ListView(
              key: const PageStorageKey('devices'),
              padding: windows
                  ? const EdgeInsets.fromLTRB(32, 28, 32, 24)
                  : const EdgeInsets.fromLTRB(16, 10, 16, 16),
              children: [
                if (windows) ...[
                  Row(children: [
                    const Expanded(
                        child: Text('连接电脑',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w600))),
                    _refreshButton(),
                    const SizedBox(width: 6),
                    FilledButton.icon(
                        onPressed: _busy ? null : _openAddDevice,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('添加电脑')),
                  ]),
                  const SizedBox(height: 16),
                  _presetBar(),
                  const SizedBox(height: 24),
                ],
                if (_loading)
                  const Padding(
                      padding: EdgeInsets.all(48),
                      child: Center(child: CircularProgressIndicator()))
                else if (_devices.isEmpty)
                  _emptyState(windows, theme)
                else
                  LayoutBuilder(builder: (context, constraints) {
                    final columns =
                        windows && constraints.maxWidth >= 520 ? 2 : 1;
                    final width =
                        (constraints.maxWidth - (columns - 1) * 16) / columns;
                    return Wrap(spacing: 16, runSpacing: 16, children: [
                      for (final device in _devices)
                        SizedBox(
                            key: ValueKey(device.id),
                            width: width,
                            child: DeviceCard(
                              device: device,
                              status: _status[device.id]?.status,
                              responseTime: _status[device.id]?.elapsed,
                              statusDetail: _status[device.id]?.detail,
                              connecting: _connectingId == device.id,
                              mobile: !windows,
                              busy: _busy,
                              onConnect: () => _connect(device),
                              onEdit: () => _openAddDevice(device),
                              onDelete: () => _deleteDevice(device),
                              onDisconnect: windows && device.paired
                                  ? () => _disconnectWindows(device)
                                  : null,
                              onAndroidHelp: Platform.isAndroid
                                  ? () => _showAndroidHelp(device)
                                  : null,
                            )),
                    ]);
                  }),
              ],
            ),
          )),
    );
  }

  Widget _emptyState(bool windows, LuluTheme theme) => Align(
        alignment: windows ? Alignment.centerLeft : Alignment.center,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: SizedBox(
                width: double.infinity,
                child: Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(windows ? 10 : 14),
                      side: BorderSide(color: theme.border)),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 48),
                      child: Column(children: [
                        Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                                color: theme.background,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: theme.border)),
                            child: Icon(Icons.desktop_windows_outlined,
                                size: 21, color: theme.muted)),
                        const SizedBox(height: 16),
                        const Text('还没有添加远程电脑',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 300),
                            child: Text('输入局域网或 Tailscale 组网地址完成配对，即可一键进入桌面。',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 13, color: theme.muted))),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: _busy ? null : _openAddDevice,
                          style: windows
                              ? null
                              : FilledButton.styleFrom(
                                  minimumSize: const Size(0, 44),
                                  shape: const StadiumBorder()),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加第一台电脑'),
                        ),
                      ])),
                ))),
      );

  Widget _preferences(bool windows) => Card(
          child: Column(children: [
        if (widget.machineSuffix != null &&
            widget.onResetActivation != null) ...[
          ListTile(
            title: Text('已激活 · ${widget.machineSuffix}'),
            subtitle: const Text('更换密钥 / 重新激活'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                        title: const Text('重新激活？'),
                        content: const Text('会清除本机的激活记录。再次进入主界面需要一枚新密钥。'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('重新激活')),
                        ],
                      ));
              if (mounted && confirmed == true) {
                widget.onResetActivation?.call();
              }
            },
          ),
          const Divider(),
        ],
        if (windows) ...[
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('串流偏好',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _presetBar(),
                  ])),
          const Divider(),
        ],
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Expanded(
                  child: Text('界面外观',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              _themeButtons(mobile: !windows),
            ])),
      ]));

  Widget _presetBar() {
    final theme = LuluTheme.of(context);
    return Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('画质预设', style: TextStyle(color: theme.muted, fontSize: 13)),
          DecoratedBox(
            decoration: BoxDecoration(
                color: theme.isDark ? theme.card : const Color(0xFFEEF2F6),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: theme.border)),
            child: Padding(
                padding: const EdgeInsets.all(3),
                child: Wrap(children: [
                  for (final preset in QualityPreset.all)
                    Semantics(
                        selected: preset.id == _preset.id,
                        child: TextButton(
                          onPressed: () => setState(
                              () => _preset = preset.withFps(_preset.fps)),
                          style: TextButton.styleFrom(
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            backgroundColor: preset.id == _preset.id
                                ? theme.selectedSegment
                                : null,
                            foregroundColor: preset.id == _preset.id
                                ? Colors.white
                                : theme.muted,
                            textStyle: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          child: Text(preset.label),
                        )),
                ])),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
                color: theme.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.border)),
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                  value: _preset.fps,
                  dropdownColor: theme.menu,
                  borderRadius: BorderRadius.circular(8),
                  isDense: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  style:
                      LuluTheme.mono.copyWith(color: theme.text, fontSize: 13),
                  items: [
                    for (final fps in [30, 60, 75, 90, 120, 144])
                      DropdownMenuItem(value: fps, child: Text('$fps FPS'))
                  ],
                  onChanged: (fps) {
                    if (fps != null) {
                      setState(() => _preset = _preset.withFps(fps));
                    }
                  },
                ))),
          ),
        ]);
  }
}
