import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/device.dart';
import '../services/component_installer.dart';
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
  bool _busy = true;
  List<({String label, String address})> _addresses = [];
  String? _message;

  @override
  void initState() {
    super.initState();
    _perform(_refresh);
  }

  Future<void> _refresh() async {
    final meshAddress = await _network.localMeshAddress();
    final adapters = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
              "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | "
              'ForEach-Object { Get-NetIPAddress -InterfaceIndex \$_.ifIndex '
              '-AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue } | '
              "Where-Object { \$_.IPAddress -notlike '169.254.*' } | "
              'Select-Object IPAddress,InterfaceAlias | ConvertTo-Json -Compress',
        ],
        stdoutEncoding: const Utf8Codec(allowMalformed: true));
    final addresses = <({String label, String address})>[];
    final output = (adapters.stdout as String).trim();
    if (adapters.exitCode == 0 && output.isNotEmpty) {
      final decoded = jsonDecode(output);
      for (final entry in decoded is List ? decoded : [decoded]) {
        addresses.add((
          label: '局域网地址 · ${entry['InterfaceAlias']}',
          address: entry['IPAddress'] as String,
        ));
      }
    }
    final status = await _network.check(Device(
      id: 'local',
      name: '这台电脑',
      meshAddress: '127.0.0.1',
    ));
    final startup =
        await Process.run('reg.exe', ['query', _runKey, '/v', _runName]);
    if (!mounted) return;
    setState(() {
      _available = status == HostStatus.online;
      _autoStart = startup.exitCode == 0;
      _addresses = [
        ...addresses,
        if (meshAddress != null) (label: '跨网地址', address: meshAddress),
      ];
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
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
      if (mounted) setState(() => _busy = false);
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
        '"${Platform.resolvedExecutable}"'
      ],
      '/f',
    ]);
    if (result.exitCode != 0) throw StateError('无法保存开机启动设置。');
    if (mounted) setState(() => _autoStart = enabled);
  }

  Future<void> _enableHost() async {
    await ComponentInstaller().prepareWindowsHost();
    await _refresh();
    if (mounted && !_available) {
      setState(() => _message = '远程服务正在启动，请稍候刷新。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('让别人连接我'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _busy ? null : () => _perform(_refresh),
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
              Text(_available ? '远程服务已开启' : '远程服务未开启'),
              if (_busy) const LinearProgressIndicator(),
              if (_message != null) ...[
                const SizedBox(height: 8),
                Text(_message!),
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
              Text('这台电脑的地址', style: Theme.of(context).textTheme.titleMedium),
              if (_addresses.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('同一网络选局域网地址，已加入同一跨网网络时选跨网地址。'),
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
                    subtitle: const Text('登录 Windows 后自动打开'),
                    value: _autoStart,
                    onChanged: _busy
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
