import 'dart:convert';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';
import 'package:xml/xml.dart';

import '../models/device.dart';
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

  Future<WindowsHostState> windowsHostState() async {
    final state = await _queryWindowsHostState();
    if (state == WindowsHostState.ready || state == WindowsHostState.unknown) {
      // A failed Windows status query must not hide a responding Sunshine host.
      if (await _localPairingEndpointsRespond()) return WindowsHostState.ready;
      if (state == WindowsHostState.ready) return WindowsHostState.starting;
    }
    return state;
  }

  /// The listeners should belong to the installed Windows service.
  Future<WindowsHostState> _queryWindowsHostState() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        _hostStateCommand,
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return WindowsHostState.unknown;
      final output = (result.stdout as String).trim();
      return WindowsHostState.values.firstWhere(
        (state) => state.name == output,
        orElse: () => WindowsHostState.unknown,
      );
    } on Exception {
      return WindowsHostState.unknown;
    }
  }

  Future<bool> _localPairingEndpointsRespond() async {
    final host = Device(id: 'local', name: '本机', meshAddress: '127.0.0.1');
    const timeout = Duration(seconds: 3);
    final client = HttpClient()
      ..connectionTimeout = timeout
      // Sunshine uses a self-signed certificate. This loopback probe sends no credentials.
      ..badCertificateCallback =
          ((certificate, address, port) => address == '127.0.0.1')
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(
        Uri.parse('${host.nvhttpBase}/serverinfo?uniqueid=lulu-probe'),
      );
      request.followRedirects = false;
      final discovery = await request.close().timeout(timeout);
      if (discovery.statusCode != HttpStatus.ok) return false;
      final xml = XmlDocument.parse(
        await discovery.transform(utf8.decoder).join().timeout(timeout),
      ).rootElement;
      if (xml.name.local != 'root' ||
          xml.getElement('appversion') == null ||
          xml.getElement('HttpsPort') == null) {
        return false;
      }

      final management = await client.getUrl(Uri.parse('${host.webBase}/'));
      management.followRedirects = false;
      final response = await management.close().timeout(timeout);
      final challenge =
          response.headers.value(HttpHeaders.wwwAuthenticateHeader);
      final redirect = response.headers.value(HttpHeaders.locationHeader);
      return (response.statusCode == HttpStatus.unauthorized &&
              challenge?.contains('Sunshine Gamestream Host') == true) ||
          (response.isRedirect && redirect == '/welcome');
    } on Exception {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static const _hostStateCommand = r'''
$ErrorActionPreference = 'Stop'
$service = Get-CimInstance Win32_Service -Filter "Name='SunshineService'"
$ports = @(47989, 47990)
$listeners = @(Get-NetTCPConnection -State Listen | Where-Object {
  $_.LocalPort -in $ports
})
$ownedProcessIds = @()
if ($service.State -eq 'Running') {
  $ownedProcessIds = @($service.ProcessId)
  $workers = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($service.ProcessId)"
  $ownedProcessIds += @($workers | ForEach-Object { $_.ProcessId })
}
if ($listeners | Where-Object { $_.OwningProcess -notin $ownedProcessIds }) {
  'portInUse'
} elseif ($service.State -ne 'Running') {
  'stopped'
} elseif (@($listeners.LocalPort | Sort-Object -Unique).Count -ne $ports.Count) {
  'starting'
} else {
  'ready'
}
''';

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

enum WindowsHostState {
  ready('远程服务已就绪'),
  stopped('远程服务未开启'),
  portInUse('连接入口正被其他程序占用。请关闭占用它的远程软件，再点右上角刷新。'),
  starting('远程服务已启动，连接入口还没就绪。请稍候再刷新。'),
  unknown('暂时无法确认远程服务状态。可点下方按钮尝试开启。');

  const WindowsHostState(this.message);

  final String message;
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
