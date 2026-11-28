import 'dart:io';

import 'package:flutter/services.dart';
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
  static const _androidChannel = MethodChannel('lulu.remote/launch');

  Future<List<SetupCheck>> runChecks() async {
    final checks = <SetupCheck>[];
    if (Platform.isWindows) {
      final moonlight = await _launcher.findWindowsClient();
      checks.add(SetupCheck(
        title: 'Moonlight Qt 可运行',
        ok: moonlight != null,
        detail: moonlight?.executable ?? '没有找到可运行的 Moonlight，请使用一键安装。',
        fixUrl: Uri.parse(
          'https://github.com/moonlight-stream/moonlight-qt/releases',
        ),
      ));
      checks.add(await _checkCommand(
        title: 'Tailscale 已安装',
        command: _tailscaleCommand(),
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
      return runAndroidChecks();
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

  Future<List<SetupCheck>> runAndroidChecks() async {
    Map<String, Object?>? apps;
    try {
      apps = await _androidChannel
          .invokeMapMethod<String, Object?>('androidConnectionApps');
    } on PlatformException {
      // An unavailable query is not evidence an app is missing.
    } on MissingPluginException {
      // A development runner may not have the Android handler.
    }
    SetupCheck app(String key, String title, String packageName, String ready) {
      final value = apps?[key];
      final available = value is bool ? value : null;
      return SetupCheck(
        title: title,
        ok: available,
        detail: switch (available) {
          true => ready,
          false => '未找到可打开的应用，请安装或启用后重新检测。',
          null => '暂时无法检测，可在系统设置里确认。',
        },
        fixUrl: Uri.parse('market://details?id=$packageName'),
      );
    }

    return [
      app('moonlight', 'Moonlight Android', 'com.limelight',
          '可以打开 Moonlight；首次连接仍需配对。'),
      app('tailscale', 'Tailscale', 'com.tailscale.ipn',
          '可以打开 Tailscale；请在其中确认组网已连接。'),
    ];
  }

  static String _tailscaleCommand() {
    final programFiles = Platform.environment['ProgramFiles'];
    if (programFiles != null) {
      final installed = File('$programFiles\\Tailscale\\tailscale.exe');
      if (installed.existsSync()) return installed.path;
    }
    return 'tailscale';
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
