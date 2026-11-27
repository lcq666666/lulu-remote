import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import 'host_setup_service.dart';
import 'moonlight_launcher.dart';

/// One-click install of the missing components, from inside LULU.
///
/// Windows: the LULU installer keeps the component installers under
/// `{app}\vendor\` on purpose, so this service can re-run them.
/// Moonlight runs silently; Tailscale runs the bundled download script
/// (official MSI from Tailscale, SHA-256 verified — see
/// installer/VERSIONS.md). Each component asks for admin (UAC) once.
/// If the bundled files are not there (e.g. a dev build run from
/// `flutter run`), it falls back to opening the official download pages.
///
/// Android: an app CANNOT silently install another app. The honest
/// maximum is one tap that opens the Play Store page, where the user
/// taps Install. The UI text must say exactly that — never promise a
/// silent install on Android.
///
/// This service installs nothing on its own initiative. The user taps
/// the "一键安装缺失组件" button first; this is what that button runs.
class ComponentInstaller {
  ComponentInstaller({HostSetupService? checks})
      : _checks = checks ?? HostSetupService();

  final HostSetupService _checks;

  static const _moonlightSetupFile = 'MoonlightSetup-6.2.0.exe';
  static const _tailscaleScriptFile = 'install-tailscale.ps1';

  static final _moonlightDownload =
      Uri.parse('https://github.com/moonlight-stream/moonlight-qt/releases');
  static final _tailscaleDownload =
      Uri.parse('https://tailscale.com/download/windows');
  static final _moonlightPlayStore =
      Uri.parse('https://play.google.com/store/apps/details?id=com.limelight');
  static final _tailscalePlayStore = Uri.parse(
      'https://play.google.com/store/apps/details?id=com.tailscale.ipn');

  /// Non-optional checks that are currently failing.
  Future<List<SetupCheck>> missingComponents() async {
    final checks = await _checks.runChecks();
    return checks.where((c) => c.ok == false && !c.optional).toList();
  }

  /// Install everything that is missing. Returns a short human-readable
  /// summary for the UI (one line per component, installed / skipped /
  /// failed). Throws only on unexpected errors; per-component failures
  /// are reported in the returned summary, not hidden.
  Future<String> installMissing() async {
    final missing = await missingComponents();
    if (missing.isEmpty) return '全部组件都已安装，不用再装。';
    if (Platform.isWindows) return _installMissingWindows(missing);
    if (Platform.isAndroid) return _installMissingAndroid(missing);
    return '当前系统不支持一键安装，请按设置检查清单手动安装。';
  }

  Future<String> _installMissingWindows(List<SetupCheck> missing) async {
    final lines = <String>[];
    for (final check in missing) {
      if (check.title.contains('Moonlight')) {
        lines.add(await _installMoonlightWindows());
      } else if (check.title.contains('Tailscale')) {
        lines.add(await _installTailscaleWindows());
      } else {
        lines.add('${check.title}：暂不支持一键安装，请手动安装。');
      }
    }
    return lines.join('\n');
  }

  Future<String> prepareWindowsController() async {
    return _installMoonlightWindows();
  }

  Future<void> prepareWindowsHost() async {
    final script = _bundledFile('prepare-host.ps1');
    if (script == null) throw StateError('请使用新版 LULU 安装包。');
    final code = await _runElevated('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '"$script"',
    ]);
    switch (code) {
      case 0:
        return;
      case 1223:
        throw StateError('Windows 的管理员确认被取消了。请在被控电脑的屏幕上重新点「允许远程控制」，然后点「是」。');
      case 5:
      case 740:
        throw StateError('Windows 拒绝了管理员权限。请用这台电脑的管理员账号开启远程控制（$code）。');
      case 3010:
        throw StateError('组件已安装，请在方便时重启电脑，再开启远程控制。');
      case -1:
        throw StateError('无法启动 Windows 的远程服务设置。请确认压缩包已完整解压再重试。');
      default:
        throw StateError('远程服务设置未完成（Windows 返回 $code）。');
    }
  }

  Future<String> _installMoonlightWindows() async {
    final setup = _bundledFile(_moonlightSetupFile);
    if (setup == null) {
      await launchUrl(_moonlightDownload, mode: LaunchMode.externalApplication);
      return 'Moonlight：安装包里没有自带安装文件，已打开官网下载页，请下载后安装。';
    }
    final result = await _runElevated(setup, ['/quiet', '/norestart']);
    if (await MoonlightLauncher().findWindowsClient() != null) {
      return 'Moonlight 可以使用了。';
    }
    return switch (result) {
      0 => '安装程序已结束，但 Moonlight 仍无法启动。请重启电脑后在连接设置中重新检测。',
      3010 || 1641 => '连接组件已安装，请重启电脑后再连接。',
      1223 => '已取消管理员确认。请重新连接并在 Windows 弹窗中点「是」。',
      _ => '连接组件安装失败（退出码 $result），请在连接设置中重试。',
    };
  }

  Future<String> _installTailscaleWindows() async {
    final script = _bundledFile(_tailscaleScriptFile);
    if (script == null) {
      await launchUrl(_tailscaleDownload, mode: LaunchMode.externalApplication);
      return 'Tailscale：安装包里没有自带脚本，已打开官网下载页，请下载后安装。';
    }
    final result = await _runElevated('powershell.exe', [
      '-ExecutionPolicy',
      'Bypass',
      '-NoProfile',
      '-File',
      script,
    ]);
    return switch (result) {
      0 => 'Tailscale 可以运行了，请在托盘图标里登录。',
      3010 || 1641 => 'Tailscale 安装需要重启 Windows。重启后请重新检测。',
      1223 => '已取消管理员确认。请重试并在 Windows 弹窗中点「是」。',
      _ => 'Tailscale 安装未完成（退出码 $result）。请检查网络后重试。',
    };
  }

  Future<String> _installMissingAndroid(List<SetupCheck> missing) async {
    // Android cannot silently install another app. One tap opens the
    // Play Store page; the user taps Install there. Say so in the UI.
    final lines = <String>[];
    for (final check in missing) {
      if (check.title.contains('Moonlight')) {
        await launchUrl(_moonlightPlayStore,
            mode: LaunchMode.externalApplication);
        lines.add('Moonlight：已打开 Play 商店，点“安装”即可（安卓不允许静默安装）。');
      } else if (check.title.contains('Tailscale')) {
        await launchUrl(_tailscalePlayStore,
            mode: LaunchMode.externalApplication);
        lines.add('Tailscale：已打开 Play 商店，点“安装”即可（安卓不允许静默安装）。');
      }
    }
    return lines.isEmpty ? '安卓端暂无可一键打开的组件。' : lines.join('\n');
  }

  /// The component installers the LULU installer keeps under
  /// `{app}\vendor\`. Returns null when this is a dev build without them.
  String? _bundledFile(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final dir in [exeDir, '$exeDir\\vendor']) {
      final file = File('$dir\\$name');
      if (file.existsSync()) return file.path;
    }
    final vendorFile = File('$exeDir\\vendor\\$name');
    return vendorFile.existsSync() ? vendorFile.path : null;
  }

  /// Run a program as administrator (UAC prompt once) and wait for it.
  /// Returns the process exit code, or -1 if it could not be started.
  Future<int> _runElevated(String program, List<String> args) async {
    try {
      String quote(String value) => "'${value.replaceAll("'", "''")}'";
      final quoted = args.map(quote).join(',');
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        'try { '
            '\$process = Start-Process -FilePath ${quote(program)} -ArgumentList $quoted '
            '-Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop; '
            '[Console]::WriteLine(\$process.ExitCode) '
            '} catch { '
            '\$failure = \$_.Exception; '
            'while (\$failure -and \$failure -isnot [ComponentModel.Win32Exception]) { '
            '\$failure = \$failure.InnerException }; '
            'if (\$failure) { [Console]::WriteLine(\$failure.NativeErrorCode) } '
            'else { [Console]::WriteLine(-1) } '
            '}',
      ]);
      return int.tryParse((result.stdout as String).trim()) ?? -1;
    } on ProcessException {
      return -1;
    }
  }
}
