import 'dart:io';

import 'package:flutter/services.dart';

import '../models/device.dart';
import '../models/quality_preset.dart';

/// Launches the stock Moonlight clients. LULU never renders video itself.
///
/// Windows: spawns `moonlight-qt.exe` as a separate process.
///   stream: moonlight-qt stream <host> "Desktop"
///             --resolution 1920x1080 --fps 60 --bitrate 15000
///             --display-mode windowed --absolute-mouse --keep-awake
///   quit:   moonlight-qt quit <host>
///   list:   moonlight-qt list <host>
/// Android: MethodChannel to MainActivity, which fires the Intent.
///   See android/app/src/main/kotlin/com/lulu/remote/MainActivity.kt.
///
/// No Moonlight / Sunshine binary is bundled by this scaffold; the
/// launcher detects the install and the setup checklist tells the user
/// what is missing.
class MoonlightLauncher {
  static const _channel = MethodChannel('lulu.remote/launch');

  /// Known install locations for moonlight-qt.exe on Windows, checked in
  /// order before falling back to PATH (`where moonlight-qt`).
  static const windowsSearchPaths = [
    r'C:\Program Files\Moonlight\moonlight-qt.exe',
    r'C:\Program Files (x86)\Moonlight\moonlight-qt.exe',
    r'%LOCALAPPDATA%\Programs\Moonlight\moonlight-qt.exe',
  ];

  Future<String?> findMoonlightQt() async {
    if (!Platform.isWindows) return null;
    for (final raw in windowsSearchPaths) {
      final expanded = raw.replaceAll(
        '%LOCALAPPDATA%',
        Platform.environment['LOCALAPPDATA'] ?? '',
      );
      if (await File(expanded).exists()) return expanded;
    }
    try {
      final result = await Process.run('where', ['moonlight-qt']);
      if (result.exitCode == 0) {
        final first = (result.stdout as String).split('\n').first.trim();
        if (first.isNotEmpty) return first;
      }
    } on ProcessException {
      // `where` not available — treat as not found.
    }
    return null;
  }

  /// One-tap connect on Windows. Returns the spawned process so the UI
  /// can show “connected” state; Moonlight owns the window after that.
  Future<Process> streamWindows(
    Device device,
    QualityPreset preset,
  ) async {
    final exe = await findMoonlightQt();
    if (exe == null) {
      throw const MoonlightNotInstalledException(
        '没有找到 moonlight-qt.exe，请先安装 Moonlight Qt（见设置检查清单）。',
      );
    }
    if (!device.paired) {
      throw const NotPairedException('这台电脑还没配对，请先在 LULU 里配对。');
    }
    return Process.start(exe, [
      'stream',
      device.meshAddress,
      device.appName,
      ...preset.cliArgs,
      '--display-mode',
      'windowed',
      // Desktop use: absolute mouse positioning, keep the host awake.
      '--absolute-mouse',
      '--keep-awake',
    ]);
  }

  Future<void> quitWindows(Device device) async {
    final exe = await findMoonlightQt();
    if (exe == null) {
      throw const MoonlightNotInstalledException('没有找到 moonlight-qt.exe。');
    }
    final result = await Process.run(exe, ['quit', device.meshAddress]);
    if (result.exitCode != 0) {
      final error = (result.stderr as String).trim();
      throw MoonlightLaunchException(
        error.isEmpty ? '断开连接失败（退出码 ${result.exitCode}）。' : error,
      );
    }
  }

  Future<String> listAppsWindows(Device device) async {
    final exe = await findMoonlightQt();
    if (exe == null) {
      throw const MoonlightNotInstalledException('没有找到 moonlight-qt.exe。');
    }
    final result = await Process.run(exe, ['list', device.meshAddress]);
    return result.stdout as String;
  }

  /// One-tap connect on Android.
  ///
  /// [useOwnCert] picks the Game Intent path (LULU's own pairing cert).
  /// It is an UNVERIFIED prototype — see MainActivity.kt and BUILD.md §4.
  /// When false, or when the Game Intent fails, call [launchShortcut]
  /// instead (Moonlight's own pairing only).
  Future<bool> streamAndroid(
    Device device, {
    required bool useOwnCert,
    required List<int> serverCertDer,
  }) async {
    if (device.hostUuid == null || device.appId == null) {
      throw const NotPairedException(
        '缺少 UUID 或应用 ID，请先配对并读取应用列表。',
      );
    }
    try {
      final ok = await _channel.invokeMethod<bool>('launchGame', {
        'host': device.meshAddress,
        'port': device.sunshinePort,
        'httpsPort': device.webPort - 6, // 47984 when base is 47989
        'appName': device.appName,
        'appId': device.appId,
        'uuid': device.hostUuid,
        'pcName': device.name,
        'hdr': false,
        'serverCert': serverCertDer,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      throw MoonlightLaunchException('拉起 Moonlight 失败：${e.message}');
    }
  }

  /// Fallback: ShortcutTrampoline Intent. Works only if this PC was
  /// paired inside Moonlight itself (Moonlight's cert, not LULU's).
  Future<bool> launchShortcut(Device device) async {
    if (device.hostUuid == null || device.appId == null) {
      throw const NotPairedException('缺少 UUID 或应用 ID。');
    }
    try {
      final ok = await _channel.invokeMethod<bool>('launchShortcut', {
        'uuid': device.hostUuid,
        'appId': device.appId,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      throw MoonlightLaunchException('拉起 Moonlight 失败：${e.message}');
    }
  }
}

class MoonlightNotInstalledException implements Exception {
  const MoonlightNotInstalledException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NotPairedException implements Exception {
  const NotPairedException(this.message);
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
