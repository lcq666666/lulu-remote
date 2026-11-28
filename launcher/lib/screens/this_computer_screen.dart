import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../services/component_installer.dart';
import '../services/host_tray.dart';
import '../services/mesh_status_service.dart';
import '../services/tray_startup.dart';
import '../widgets/auto_lock_tile.dart';
import '../widgets/lulu_ui.dart';
import '../widgets/connection_log_view.dart';
import '../widgets/file_transfer_settings.dart';
import '../widgets/privacy_screen_settings.dart';
import 'setup_checklist_screen.dart';

class ThisComputerScreen extends StatefulWidget {
  const ThisComputerScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<ThisComputerScreen> createState() => _ThisComputerScreenState();
}

class _ThisComputerScreenState extends State<ThisComputerScreen> {
  final _startup = const TrayStartup();
  final _network = MeshStatusService();
  bool _available = false;
  bool _autoStart = false;
  bool _installedStartup = false;
  bool _busy = true;
  List<LocalAddress> _addresses = [];
  String? _message;
  String? _hostFailure;
  Timer? _hostRetry;

  @override
  void initState() {
    super.initState();
    _perform(_refresh);
  }

  @override
  void dispose() {
    _hostRetry?.cancel();
    super.dispose();
  }

  Future<String?> _readHostFailure() async {
    try {
      await _network.verifyLocalHost();
      return null;
    } on StateError catch (error) {
      return error.message;
    }
  }

  void _scheduleHostRetry() {
    _hostRetry = Timer(const Duration(seconds: 2), () async {
      final currentRetry = _hostRetry;
      final failure = await _readHostFailure();
      if (!mounted || _hostRetry != currentRetry) return;
      _hostRetry = null;
      setState(() {
        _hostFailure = failure;
        _available = failure == null;
      });
      if (!_available) _scheduleHostRetry();
    });
  }

  Future<void> _refresh() async {
    final addresses = await _network.localAddresses();
    final hostFailure = await _readHostFailure();
    final startup = await _startup.read();
    if (!mounted) return;
    setState(() {
      _installedStartup = startup.host;
      _available = hostFailure == null;
      _hostFailure = hostFailure;
      _autoStart = startup.user;
      _addresses = addresses;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    _hostRetry?.cancel();
    _hostRetry = null;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
            () => _message = error is StateError ? error.message : '操作失败，请重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (!_available) _scheduleHostRetry();
      }
    }
  }

  Future<void> _setAutoStart(bool enabled) async {
    await _startup.setUserEnabled(enabled, Platform.resolvedExecutable);
    if (mounted) setState(() => _autoStart = enabled);
  }

  Future<void> _enableHost() async {
    await ComponentInstaller().prepareWindowsHost();
    await _refresh();
  }

  Future<void> _copyAddress(String address) async {
    try {
      await Clipboard.setData(ClipboardData(text: address));
      if (mounted) showLuluSnack(context, '已复制电脑地址。', success: true);
    } catch (_) {
      if (mounted) showLuluSnack(context, '无法复制地址，请选中地址手动复制。');
    }
  }

  Future<void> _openServiceManager() async {
    try {
      await Process.start('mmc.exe', ['services.msc'],
          mode: ProcessStartMode.detached);
      if (mounted) {
        showLuluSnack(context, '可在 Windows 服务中启动或停止 Sunshine Service。');
      }
    } on ProcessException {
      if (mounted) showLuluSnack(context, '无法打开 Windows 服务管理器。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    final content = Align(
      alignment: widget.embedded ? Alignment.topLeft : Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 804),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
          children: [
            Row(children: [
              const Expanded(
                  child: Text('让别人连接我',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w600))),
              IconButton(
                  tooltip: '刷新状态',
                  onPressed: _busy ? null : () => _perform(_refresh),
                  icon: const Icon(Icons.refresh)),
            ]),
            Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(Icons.laptop_windows_outlined,
                      size: 16, color: theme.muted),
                  Text('本机主机名 ·',
                      style: TextStyle(color: theme.muted, fontSize: 13)),
                  SelectableText(Platform.localHostname,
                      style: LuluTheme.mono
                          .copyWith(fontSize: 13, fontWeight: FontWeight.w500)),
                ]),
            const SizedBox(height: 20),
            _serviceCard(theme),
            const SizedBox(height: 16),
            _addressCard(theme),
            const SizedBox(height: 16),
            _managementCard(),
          ],
        ),
      ),
    );
    return widget.embedded
        ? content
        : Scaffold(appBar: AppBar(), body: content);
  }

  Widget _serviceCard(LuluTheme theme) {
    final color = _busy
        ? theme.muted
        : _available
            ? theme.success
            : theme.warning;
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          LuluStatusDot(
              color: _available && !_busy ? theme.online : color,
              glow: _available && !_busy,
              size: 10),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  _busy
                      ? '正在检查远程服务…'
                      : _available
                          ? '远程服务已开启'
                          : '远程服务暂未就绪',
                  style: TextStyle(
                      color: color,
                      fontSize: 16,
                      fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 6),
        Text(_available ? '受信任设备可通过下方地址连接这台电脑。' : '开启远程控制后，对方就能通过下方地址发起连接。',
            style: TextStyle(color: theme.muted, fontSize: 13)),
        if (_busy)
          const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2)),
        if ((_message ?? _hostFailure) case final message?)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message,
                  style: TextStyle(color: theme.warning, fontSize: 13))),
        const SizedBox(height: 12),
        Align(
            alignment: Alignment.centerRight,
            child: _available
                ? OutlinedButton.icon(
                    onPressed: _busy ? null : _openServiceManager,
                    icon: const Icon(Icons.power_settings_new, size: 16),
                    label: const Text('管理服务启停'))
                : FilledButton.icon(
                    onPressed: _busy ? null : () => _perform(_enableHost),
                    icon: const Icon(Icons.power_settings_new, size: 16),
                    label: const Text('允许远程控制'))),
      ]),
    ));
  }

  Widget _addressCard(LuluTheme theme) => Card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('这台电脑的地址',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('同一局域网用局域网地址。跨网连接时，选两台电脑都已接入的组网。',
                  style: TextStyle(fontSize: 13, color: theme.muted)),
            ])),
        if (_addresses.isEmpty && !_busy) ...[
          const Divider(),
          const ListTile(title: Text('未找到地址，请检查本机网络。')),
        ],
        for (final entry in _addresses) ...[
          const Divider(),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: SelectableText(entry.address,
                style: LuluTheme.mono.copyWith(fontSize: 14)),
            subtitle: Text(entry.label,
                style: TextStyle(fontSize: 12, color: theme.muted)),
            trailing: IconButton(
                tooltip: '复制 ${entry.address}',
                icon: const Icon(Icons.copy_outlined, size: 17),
                onPressed: () => _copyAddress(entry.address)),
          ),
        ],
      ]));

  Widget _managementCard() => Card(
          child: ExpansionTile(
        leading: const Icon(Icons.build_outlined, size: 18),
        title: const Text('管理与故障检查',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        children: [
          const Divider(),
          SwitchListTile(
            title: const Text('登录 Windows 后启动托盘'),
            subtitle: Text(_installedStartup
                ? '已找到主机安装器配置的托盘启动项。实际启动由 Windows 管理。'
                : '登录后在托盘等待配对。若没有启动，请检查 Windows 的「启动应用」。'),
            value: _autoStart || _installedStartup,
            onChanged: _busy || _installedStartup
                ? null
                : (value) => _perform(() => _setAutoStart(value)),
          ),
          if (_available) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('设置配对提醒'),
              onTap: _busy ? null : HostTray.instance.register,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('打开 Sunshine 管理页'),
              subtitle: const Text('首次配置或忘记账号时使用'),
              trailing: const Icon(Icons.open_in_new, size: 17),
              onTap: _busy
                  ? null
                  : () => _perform(() async {
                        if (!await launchUrl(
                            Uri.parse('https://localhost:47990'),
                            mode: LaunchMode.externalApplication)) {
                          throw StateError('无法打开本机管理页面。');
                        }
                      }),
            ),
          ],
          const Divider(),
          const PrivacyScreenSettings(),
          const Divider(),
          const FileTransferSettings(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('连接记录'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const ConnectionLogView())),
          ),
          const Divider(),
          const AutoLockTile(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('检查连接组件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const SetupChecklistScreen())),
          ),
        ],
      ));
}
