import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import 'moonlight_launcher.dart';

/// Setup checklist: is everything the launcher needs actually installed?
///
/// Windows launcher PC: Moonlight Qt + a mesh client (Tailscale first).
/// Remote PC: Sunshine + the same mesh client — the host-setup script in
/// ../scripts/host-setup/install-sunshine.ps1 does that side; this
/// service only checks the local side and opens the script / download
/// pages. Nothing here installs anything silently.
class HostSetupService {
  HostSetupService({MoonlightLauncher? launcher})
      : _launcher = launcher ?? MoonlightLauncher();

  final MoonlightLauncher _launcher;

  Future<List<SetupCheck>> runChecks() async {
    final checks = <SetupCheck>[];
    if (Platform.isWindows) {
      final moonlight = await _launcher.findMoonlightQt();
      checks.add(SetupCheck(
        title: 'Moonlight Qt 已安装',
        ok: moonlight != null,
        detail: moonlight ?? '没有找到 moonlight-qt.exe',
        fixUrl: Uri.parse(
          'https://github.com/moonlight-stream/moonlight-qt/releases',
        ),
      ));
      checks.add(await _checkCommand(
        title: 'Tailscale 已安装',
        command: 'tailscale',
        args: ['version'],
        fixUrl: Uri.parse('https://tailscale.com/download/windows'),
      ));
      checks.add(await _checkCommand(
        title: 'ZeroTier 已安装（备选组网）',
        command: 'zerotier-cli',
        args: ['info'],
        optional: true,
        fixUrl: Uri.parse('https://www.zerotier.com/download/'),
      ));
    } else if (Platform.isAndroid) {
      checks.add(SetupCheck(
        title: 'Moonlight Android',
        ok: false,
        detail: '用于串流，请到 Play 商店确认已安装。',
        fixUrl: Uri.parse('market://details?id=com.limelight'),
      ));
      checks.add(SetupCheck(
        title: 'Tailscale',
        ok: false,
        detail: '用于组网，请到 Play 商店确认已安装。',
        fixUrl: Uri.parse('market://details?id=com.tailscale.ipn'),
      ));
    } else {
      checks.add(const SetupCheck(
        title: 'Moonlight Android 已安装',
        ok: null, // Cannot be probed from Flutter; the launch attempt is the check.
        detail: '点连接时拉起，失败会提示安装。',
        fixUrl: null,
      ));
    }
    return checks;
  }

  Future<SetupCheck> _checkCommand({
    required String title,
    required String command,
    required List<String> args,
    Uri? fixUrl,
    bool optional = false,
  }) async {
    try {
      final result = await Process.run(command, args);
      return SetupCheck(
        title: title,
        ok: result.exitCode == 0,
        detail: result.exitCode == 0
            ? (result.stdout as String).trim().split('\n').first
            : '命令返回 ${result.exitCode}',
        fixUrl: fixUrl,
        optional: optional,
      );
    } on ProcessException {
      return SetupCheck(
        title: title,
        ok: false,
        detail: '没有找到 $command',
        fixUrl: fixUrl,
        optional: optional,
      );
    }
  }

  Future<void> openFix(SetupCheck check) async {
    final url = check.fixUrl;
    if (url == null) return;
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && Platform.isAndroid) {
      throw StateError('无法打开 ${check.title} 的下载页面。');
    }
  }
}

class SetupCheck {
  const SetupCheck({
    required this.title,
    required this.ok,
    required this.detail,
    required this.fixUrl,
    this.optional = false,
  });

  final String title;
  final bool? ok; // null = cannot be probed on this platform
  final String detail;
  final Uri? fixUrl;
  final bool optional;
}
