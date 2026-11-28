import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/device.dart';
import '../models/quality_preset.dart';

/// Launches the stock Moonlight clients. LULU never renders video itself.
class MoonlightLauncher {
  static const _channel = MethodChannel('lulu.remote/launch');
  static const _windowsChannel = MethodChannel('lulu/host_tray');

  Future<bool> isInstalled() async {
    if (Platform.isWindows) return await findWindowsClient() != null;
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('isMoonlightInstalled') ?? false;
    }
    return false;
  }

  static Iterable<String> get _installedCandidates sync* {
    final env = Platform.environment;
    for (final root in {
      env['ProgramW6432'],
      env['ProgramFiles'],
      env['ProgramFiles(x86)'],
      if (env['LOCALAPPDATA'] case final String local) '$local\\Programs',
    }.whereType<String>()) {
      yield '$root\\Moonlight Game Streaming\\Moonlight.exe';
      yield '$root\\Moonlight\\Moonlight.exe';
      yield '$root\\Moonlight\\moonlight-qt.exe';
    }
  }

  Future<WindowsMoonlight?> findWindowsClient() async {
    if (!Platform.isWindows) return null;
    final appDirectory = File(Platform.resolvedExecutable).parent;
    // Outside of the vendor directory, Qt uses the existing Windows profile
    // instead of the bundled portable.dat. Keep this directory for all calls.
    final bundled = '${appDirectory.path}\\vendor\\moonlight\\Moonlight.exe';
    final examined = <String>{};
    Future<WindowsMoonlight?> firstWorking(Iterable<String> paths) async {
      for (final path in paths) {
        if (!examined.add(path.toLowerCase()) || !await File(path).exists()) {
          continue;
        }
        final client = WindowsMoonlight(path, appDirectory.path);
        if (await client.canStart()) return client;
      }
      return null;
    }

    final known = await firstWorking([bundled, ..._installedCandidates]);
    if (known != null) return known;

    // Stock MSI installations with a custom directory still have a shortcut.
    // Use only the target and run the same --version probe as other clients.
    try {
      final links = await _windowsChannel
          .invokeListMethod<String>('moonlightStartMenuTargets');
      final registered = await firstWorking(links ?? const []);
      if (registered != null) return registered;
    } on PlatformException {
      // Lookup is optional; PATH remains available.
    } on MissingPluginException {
      // A development runner may not yet have the Windows handler.
    }

    final where = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
        r'\System32\where.exe';
    try {
      final result = await _runCommand(
          where, ['Moonlight.exe', 'moonlight-qt.exe'],
          directory: appDirectory.path, timeout: const Duration(seconds: 3));
      final paths =
          LineSplitter.split(result.stdout).map((line) => line.trim());
      return firstWorking(paths.where((path) => File(path).isAbsolute));
    } on ProcessException {
      // PATH lookup is optional.
    } on TimeoutException {
      // PATH can include unavailable network drives.
    }
    return null;
  }

  Future<void> quitWindows(Device device) async {
    final client = await findWindowsClient();
    if (client == null) {
      throw const MoonlightNotInstalledException('没有可运行的 Windows 连接组件。');
    }
    await client.quit(device);
  }

  Future<bool> openAndroid() async =>
      await _channel.invokeMethod<bool>('openMoonlight') ?? false;

  /// Moonlight resolves the host and uses its own pairing credentials.
  /// A true return value indicates that Android accepted the launch request.
  Future<bool> launchAndroidShortcut(Device device, String hostUuid) async {
    final appId = device.appId;
    return await _channel.invokeMethod<bool>('launchShortcut', {
          'uuid': hostUuid,
          'appName': device.appName,
          if (appId != null && appId > 0) 'appId': appId,
        }) ??
        false;
  }
}

/// A single Moonlight executable and profile used throughout a connection.
class WindowsMoonlight {
  const WindowsMoonlight(this.executable, this.directory);

  final String executable;
  final String directory;

  static String endpoint(Device device) {
    if (device.sunshinePort == 47989) return device.meshAddress;
    return Uri(host: device.meshAddress, port: device.sunshinePort).authority;
  }

  Future<bool> canStart() async {
    try {
      final result = await _runCommand(executable, ['--version'],
          directory: directory, timeout: const Duration(seconds: 5));
      return result.exitCode == 0 && result.stdout.contains('Moonlight');
    } on ProcessException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// Moonlight 6.2 exits with -1 when the host is unpaired or cannot be
  /// discovered. The caller checks host reachability before offering pairing.
  Future<List<String>?> listApps(Device device) async {
    final result = await _command('list', device);
    if (result.exitCode == -1 || result.exitCode == 0xffffffff) return null;
    if (result.exitCode != 0) {
      throw MoonlightLaunchException(
          'Moonlight 无法读取「${device.name}」的应用列表（退出码 ${result.exitCode}）。');
    }
    return LineSplitter.split(result.stdout)
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// The stock client shows the PIN and owns the pairing window. Its exit
  /// code does not confirm success. Only a later successful list does.
  Future<void> pair(Device device) async {
    final process = await Process.start(executable, ['pair', endpoint(device)],
        workingDirectory: directory);
    final stdout = process.stdout.drain<void>();
    final stderr = process.stderr.drain<void>();
    await process.exitCode;
    await Future.wait([stdout, stderr]);
  }

  Future<Process> stream(Device device, QualityPreset preset) => Process.start(
        executable,
        [
          'stream',
          endpoint(device),
          device.appName,
          ...preset.cliArgs,
          '--display-mode',
          'windowed',
          '--absolute-mouse',
          '--keep-awake',
        ],
        workingDirectory: directory,
      );

  Future<void> quit(Device device) async {
    final result = await _command('quit', device);
    if (result.exitCode != 0) {
      throw MoonlightLaunchException('断开连接失败（退出码 ${result.exitCode}）。');
    }
  }

  Future<_CommandResult> _command(String command, Device device) async {
    try {
      return await _runCommand(executable, [command, endpoint(device)],
          directory: directory, timeout: const Duration(seconds: 38));
    } on TimeoutException {
      throw MoonlightLaunchException('Moonlight 连接「${device.name}」超时，请重试。');
    } on ProcessException {
      throw const MoonlightLaunchException('无法启动 Moonlight，请在连接设置中重新检测组件。');
    }
  }
}

typedef _CommandResult = ({int exitCode, String stdout});

Future<_CommandResult> _runCommand(
  String executable,
  List<String> arguments, {
  required String directory,
  required Duration timeout,
}) async {
  final process =
      await Process.start(executable, arguments, workingDirectory: directory);
  final stdout =
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final stderr = process.stderr.drain<void>();
  final result = () async {
    final code = await process.exitCode;
    await stderr;
    return (exitCode: code, stdout: await stdout);
  }();
  return result.timeout(timeout, onTimeout: () {
    process.kill();
    throw TimeoutException('Moonlight command timed out', timeout);
  });
}

class MoonlightNotInstalledException implements Exception {
  const MoonlightNotInstalledException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MoonlightLaunchException implements Exception {
  const MoonlightLaunchException(this.message);
  final String message;
  @override
  String toString() => message;
}
