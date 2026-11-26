import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../services/host_setup_service.dart';

/// Setup checklist: what is installed, what is missing, and the fix.
///
/// Nothing here installs anything silently. The remote-PC side is the
/// script in ../scripts/host-setup/install-sunshine.ps1 — the checklist
/// shows the exact command to run it on the remote PC.
class SetupChecklistScreen extends StatefulWidget {
  const SetupChecklistScreen({super.key});

  @override
  State<SetupChecklistScreen> createState() => _SetupChecklistScreenState();
}

class _SetupChecklistScreenState extends State<SetupChecklistScreen> {
  final _service = HostSetupService();
  List<SetupCheck>? _checks;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final checks = await _service.runChecks();
    if (mounted) setState(() => _checks = checks);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置检查清单')),
      body: _checks == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
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
                            onPressed: () => _service.openFix(check),
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
                  '第一次请在远端电脑上看着它跑完。',
                  style: TextStyle(color: LuluTheme.muted, fontSize: 12),
                ),
              ],
            ),
    );
  }
}
