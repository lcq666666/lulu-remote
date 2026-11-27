import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/component_installer.dart';
import '../services/host_tray.dart';
import '../services/mesh_status_service.dart';
import 'setup_checklist_screen.dart';

class ThisComputerScreen extends StatefulWidget {
  const ThisComputerScreen({super.key});

  @override
  State<ThisComputerScreen> createState() => _ThisComputerScreenState();
}

class _ThisComputerScreenState extends State<ThisComputerScreen> {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runName = 'LULU Remote';
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
    final startup =
        await Process.run('reg.exe', ['query', _runKey, '/v', _runName]);
    final installedStartup = await Process.run('reg.exe', [
      'query',
      r'HKLM\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'LULU Remote Host',
      '/reg:64',
    ]);
    if (!mounted) return;
    setState(() {
      _installedStartup = installedStartup.exitCode == 0;
      _available = hostFailure == null;
      _hostFailure = hostFailure;
      _autoStart = startup.exitCode == 0;
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
    final result = await Process.run('reg.exe', [
      enabled ? 'add' : 'delete',
      _runKey,
      '/v',
      _runName,
      if (enabled) ...[
        '/t',
        'REG_SZ',
        '/d',
        '"${Platform.resolvedExecutable}" --tray'
      ],
      '/f',
    ]);
    if (result.exitCode != 0) throw StateError('无法保存开机启动设置。');
    if (mounted) setState(() => _autoStart = enabled);
  }

  Future<void> _enableHost() async {
    await ComponentInstaller().prepareWindowsHost();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('让别人连接我'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _busy ? null : () => _perform(() => _refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(Platform.localHostname,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(_busy
                  ? '正在检查远程服务…'
                  : _available
                      ? '远程服务已开启'
                      : '远程服务暂未就绪，正在自动检查'),
              if (_busy) const LinearProgressIndicator(),
              if ((_message ?? _hostFailure) case final message?) ...[
                const SizedBox(height: 8),
                Text(message),
              ],
              const SizedBox(height: 16),
              if (!_available)
                Align(
                  alignment: Alignment.centerLeft,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : () => _perform(_enableHost),
                    icon: const Icon(Icons.desktop_windows_outlined),
                    label: const Text('允许远程控制'),
                  ),
                ),
              const SizedBox(height: 24),
              if (_available) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : HostTray.instance.register,
                    icon: const Icon(Icons.notifications_outlined),
                    label: const Text('设置配对提醒'),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text('这台电脑的地址', style: Theme.of(context).textTheme.titleMedium),
              if (_addresses.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('同一局域网用局域网地址。跨网连接请选择两台电脑都已接入的网络。'),
                ),
              if (_addresses.isEmpty && !_busy)
                const ListTile(title: Text('未找到地址，请检查本机网络。')),
              for (final entry in _addresses)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: SelectableText(entry.address),
                  subtitle: Text(entry.label),
                  trailing: IconButton(
                    tooltip: '复制地址',
                    icon: const Icon(Icons.copy),
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: entry.address));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制电脑地址。')),
                        );
                      }
                    },
                  ),
                ),
              const Divider(),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_outlined),
                title: const Text('管理与故障检查'),
                children: [
                  if (_available)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.manage_accounts_outlined),
                      title: const Text('设置本机管理账号'),
                      subtitle: const Text('首次配置或忘记账号时使用'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: _busy
                          ? null
                          : () => _perform(() async {
                                if (!await launchUrl(
                                  Uri.parse('https://localhost:47990'),
                                  mode: LaunchMode.externalApplication,
                                )) {
                                  throw StateError('无法打开本机管理页面。');
                                }
                              }),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开机启动 LULU'),
                    subtitle: Text(_installedStartup
                        ? '主机安装器已开启托盘启动'
                        : '登录 Windows 后在托盘等待配对'),
                    value: _autoStart || _installedStartup,
                    onChanged: _busy || _installedStartup
                        ? null
                        : (value) => _perform(() => _setAutoStart(value)),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('检查连接组件'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const SetupChecklistScreen()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
