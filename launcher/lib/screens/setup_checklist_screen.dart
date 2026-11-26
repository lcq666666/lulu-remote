import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../services/component_installer.dart';
import '../services/host_setup_service.dart';

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
  const SetupChecklistScreen({super.key});

  @override
  State<SetupChecklistScreen> createState() => _SetupChecklistScreenState();
}

class _SetupChecklistScreenState extends State<SetupChecklistScreen> {
  final _service = HostSetupService();
  final _installer = ComponentInstaller();
  List<SetupCheck>? _checks;
  bool _installing = false;
  String? _installResult;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final checks = await _service.runChecks();
    if (mounted) setState(() => _checks = checks);
  }

  Future<void> _installMissing() async {
    setState(() {
      _installing = true;
      _installResult = null;
    });
    final result = await _installer.installMissing();
    if (!mounted) return;
    setState(() {
      _installing = false;
      _installResult = result;
    });
    await _run();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('安装已跑完，上面是每项的结果。')),
      );
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

  @override
  Widget build(BuildContext context) {
    final missing =
        (_checks ?? []).where((c) => c.ok == false && !c.optional).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('设置检查清单')),
      body: _checks == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (missing.isNotEmpty) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _installing
                          ? null
                          : Platform.isAndroid
                              ? () => _chooseAndroidComponent(missing)
                              : _installMissing,
                      icon: _installing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      label: Text(_installing
                          ? '正在安装，请稍等…'
                          : Platform.isAndroid
                              ? '一键打开安装（Moonlight / Tailscale）'
                              : '一键安装缺失组件'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Platform.isAndroid
                        ? '选一个组件打开 Play 商店，安装后返回这里打开另一项。'
                        : '点一下就装好缺的组件，每装一个会弹一次管理员确认，'
                            '不用你再去各家官网下载。',
                    style:
                        const TextStyle(color: LuluTheme.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_installResult != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: LuluTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: LuluTheme.border),
                    ),
                    child: Text(_installResult!),
                  ),
                  const SizedBox(height: 8),
                ],
                for (final check in _checks!) ...[
                  ListTile(
                    leading: Icon(
                      check.ok == null
                          ? Icons.help_outline
                          : check.ok!
                              ? Icons.check_circle
                              : Icons.error_outline,
                      color: check.ok == null
                          ? LuluTheme.muted
                          : check.ok!
                              ? LuluTheme.accent
                              : Colors.redAccent,
                    ),
                    title: Text(check.title),
                    subtitle: Text(check.detail),
                    trailing: check.fixUrl == null || check.ok == true
                        ? null
                        : TextButton(
                            onPressed: Platform.isAndroid
                                ? () => _openAndroidStore(check)
                                : () => _service.openFix(check),
                            child: const Text('去下载'),
                          ),
                  ),
                  const Divider(color: LuluTheme.border),
                ],
                const SizedBox(height: 8),
                const Text(
                  '远端电脑一键配置（在远端电脑上用管理员 PowerShell 运行）：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: LuluTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: LuluTheme.border),
                  ),
                  child: const SelectableText(
                    'powershell -ExecutionPolicy Bypass -File '
                    'scripts\\host-setup\\install-sunshine.ps1',
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(
                      text:
                          'powershell -ExecutionPolicy Bypass -File scripts\\host-setup\\install-sunshine.ps1',
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制命令。')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('复制命令'),
                ),
                const Text(
                  '这个脚本用 winget 装 Sunshine 和 Tailscale、放行防火墙端口、'
                  '并打开 Sunshine 网页让管理员创建账号。脚本本身没有经过真机运行，'
                  '第一次请在远端电脑上看着它跑完。更省事的做法：在远端电脑上直接'
                  '运行 LULU-Host-Setup 安装包，上面这些步骤它都包了。',
                  style: TextStyle(color: LuluTheme.muted, fontSize: 12),
                ),
              ],
            ),
    );
  }
}
