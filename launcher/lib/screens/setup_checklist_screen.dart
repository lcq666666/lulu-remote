import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../services/component_installer.dart';
import '../services/host_setup_service.dart';
import '../widgets/lulu_ui.dart';

/// Setup checklist: what is installed, what is missing, and the fix.
///
/// First run: one big "一键安装缺失组件" button at the top. It only
/// appears when a required component is missing; tapping it installs
/// everything missing and then re-runs the checks.
///
/// Windows: the bundled installers under {app}\vendor\ are re-run
/// (Moonlight silently, Tailscale via its download script). Each one
/// asks for admin (UAC) once.
///
/// Android: an app CANNOT silently install another app. The button
/// only opens the Play Store pages for Moonlight and Tailscale, and
/// the text under it says exactly that — never promise a silent
/// install on Android.
///
/// The remote-PC side is the script in ../scripts/host-setup/install-sunshine.ps1
/// (or the LULU-Host-Setup installer, which does the same steps) —
/// the checklist shows the exact command to run it on the remote PC.
class SetupChecklistScreen extends StatefulWidget {
  const SetupChecklistScreen(
      {super.key,
      this.embedded = false,
      this.showTitle = true,
      this.preferences});

  final bool embedded;
  final bool showTitle;
  final Widget? preferences;

  @override
  State<SetupChecklistScreen> createState() => _SetupChecklistScreenState();
}

class _SetupChecklistScreenState extends State<SetupChecklistScreen> {
  final _service = HostSetupService();
  final _installer = ComponentInstaller();
  List<SetupCheck>? _checks;
  bool _installing = false;
  bool _checking = false;
  String? _checkError;
  String? _installResult;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final checks = await _service.runChecks();
      if (mounted) setState(() => _checks = checks);
    } catch (_) {
      if (mounted) setState(() => _checkError = '检测未完成，请重新检测。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _installMissing() async {
    setState(() {
      _installing = true;
      _installResult = null;
    });
    try {
      final result = await _installer.installMissing();
      if (!mounted) return;
      setState(() => _installResult = result);
      await _run();
      if (mounted) showLuluSnack(context, '安装已完成，可查看每项结果。');
    } catch (_) {
      if (mounted) setState(() => _installResult = '安装未完成，请重试。');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _openAndroidStore(SetupCheck check) async {
    setState(() => _installResult = null);
    try {
      await _service.openFix(check);
    } catch (_) {
      if (!mounted) return;
      setState(() => _installResult = '无法打开 Play 商店。请确认手机装有 Play 商店，或在浏览器访问 '
          'play.google.com 搜索 ${check.title}。');
    }
  }

  Future<void> _chooseAndroidComponent(List<SetupCheck> options) async {
    setState(() => _installResult = null);
    final selected = await showDialog<SetupCheck>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择要打开的 Play 商店页面'),
        children: [
          for (final check in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, check),
              child: Text(check.title),
            ),
        ],
      ),
    );
    if (mounted && selected != null) await _openAndroidStore(selected);
  }

  static const _hostCommand = 'powershell -ExecutionPolicy Bypass -File '
      'scripts\\host-setup\\install-sunshine.ps1';

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    final android = Platform.isAndroid;
    final checks = _checks ?? const <SetupCheck>[];
    final missing =
        checks.where((check) => check.ok == false && !check.optional).toList();
    final content = Align(
      alignment:
          widget.embedded && !android ? Alignment.topLeft : Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 804),
        child: ListView(
          padding: android
              ? const EdgeInsets.fromLTRB(16, 10, 16, 20)
              : const EdgeInsets.fromLTRB(32, 28, 32, 24),
          children: [
            if (widget.embedded && widget.showTitle) ...[
              const Text('连接设置',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
            ],
            Card(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Row(children: [
                        const Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text('连接诊断',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ])),
                        OutlinedButton.icon(
                          onPressed: _checking || _installing ? null : _run,
                          icon: _checking
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.refresh, size: 16),
                          label: const Text('重新检测'),
                        ),
                      ])),
                  if (_checking) const LinearProgressIndicator(minHeight: 2),
                  if (_checkError != null)
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_checkError!,
                            style: TextStyle(color: theme.warning))),
                  for (final check in checks) ...[
                    const Divider(),
                    _checkRow(check, theme, android),
                  ],
                  if (missing.isNotEmpty) ...[
                    const Divider(),
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FilledButton.icon(
                                onPressed: _checking || _installing
                                    ? null
                                    : android
                                        ? () => _chooseAndroidComponent(missing)
                                        : _installMissing,
                                icon: _installing
                                    ? const SizedBox.square(
                                        dimension: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.download_outlined,
                                        size: 17),
                                label: Text(_installing
                                    ? '正在安装…'
                                    : android
                                        ? '打开商店安装组件'
                                        : '一键安装缺失组件'),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                  android
                                      ? '打开 Play 商店后，在商店中确认安装。'
                                      : '每个组件安装前，Windows 会弹出管理员确认。',
                                  style: TextStyle(
                                      color: theme.muted, fontSize: 12)),
                            ])),
                  ],
                  if (_installResult != null) ...[
                    const Divider(),
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_installResult!)),
                  ],
                ])),
            if (widget.preferences != null) ...[
              const SizedBox(height: 16),
              widget.preferences!,
            ],
            const SizedBox(height: 16),
            Card(
                child: ExpansionTile(
              leading: const Icon(Icons.desktop_windows_outlined, size: 18),
              title: const Text('远端电脑配置',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '可在远端电脑运行 LULU-Host-Setup 安装包，或用管理员 PowerShell 运行仓库中的主机配置脚本。',
                    style: TextStyle(fontSize: 13, color: theme.muted)),
                const SizedBox(height: 8),
                SelectableText(_hostCommand,
                    style: LuluTheme.mono.copyWith(fontSize: 12)),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                        const ClipboardData(text: _hostCommand));
                    if (context.mounted) {
                      showLuluSnack(context, '已复制命令。', success: true);
                    }
                  },
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: const Text('复制命令'),
                ),
              ],
            )),
          ],
        ),
      ),
    );
    return widget.embedded
        ? content
        : Scaffold(appBar: AppBar(title: const Text('连接设置')), body: content);
  }

  Widget _checkRow(SetupCheck check, LuluTheme theme, bool android) {
    final (label, icon, color) = switch (check.ok) {
      true => ('正常', Icons.check_circle_outline, theme.success),
      false when android => ('待确认', Icons.info_outline, theme.muted),
      false => (
          check.optional ? '未安装' : '需安装',
          Icons.error_outline,
          check.optional ? theme.muted : theme.warning
        ),
      null => ('待确认', Icons.info_outline, theme.muted),
    };
    final canFix = check.fixUrl != null && check.ok != true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(check.title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(check.detail,
              style: TextStyle(color: theme.muted, fontSize: 12)),
          if (canFix)
            TextButton(
              onPressed: _installing
                  ? null
                  : () async {
                      if (android) {
                        await _openAndroidStore(check);
                      } else {
                        await _service.openFix(check);
                      }
                    },
              child: const Text('去下载'),
            ),
        ])),
        const SizedBox(width: 8),
        LuluBadge(label: label, icon: icon, color: color),
      ]),
    );
  }
}
