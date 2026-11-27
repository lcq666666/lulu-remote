import 'dart:async';
import 'dart:convert';
import 'dart:io';

class HostHardware {
  const HostHardware(
      {required this.cpu,
      required this.ramBytes,
      required this.diskBytes,
      required this.diskFreeBytes,
      required this.os});

  factory HostHardware.fromJson(Map<String, dynamic> json) {
    return HostHardware(
        cpu: _text(json, 'cpu'),
        os: _text(json, 'os'),
        ramBytes: _bytes(json, 'ramBytes'),
        diskBytes: _bytes(json, 'diskBytes'),
        diskFreeBytes: _bytes(json, 'diskFreeBytes'));
  }

  final String cpu;
  final int ramBytes;
  final int diskBytes;
  final int diskFreeBytes;
  final String os;

  static String _text(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty || value.length > 1024) {
      throw const FormatException('Invalid hardware information');
    }
    return value.trim();
  }

  static int _bytes(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! int || value < 0) {
      throw const FormatException('Invalid storage size');
    }
    return value;
  }

  Map<String, dynamic> toJson() => {
        'cpu': cpu,
        'ramBytes': ramBytes,
        'diskBytes': diskBytes,
        'diskFreeBytes': diskFreeBytes,
        'os': os
      };

  static String _gib(int bytes) =>
      '${(bytes / (1 << 30)).toStringAsFixed(1)} GiB';

  String get summary =>
      'CPU：$cpu\n内存：${_gib(ramBytes)}\n系统盘：${_gib(diskFreeBytes)} 可用 / ${_gib(diskBytes)}\n系统：$os';

  static const _query = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$system = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$processors = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() } | Select-Object -Unique)
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($os.SystemDrive)'"
if (!$disk -or !$processors -or !$system.TotalPhysicalMemory) { exit 1 }
@{ cpu = $processors -join ' / '; ramBytes = $system.TotalPhysicalMemory;
   diskBytes = $disk.Size; diskFreeBytes = $disk.FreeSpace;
   os = "$($os.Caption.Trim()) ($($os.Version))" } | ConvertTo-Json -Compress
''';

  static Future<HostHardware> readWindows() async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final process = await Process.start(
      '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', _query],
    );
    try {
      final results = await Future.wait<Object>([
        process.exitCode,
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.drain<void>().then((_) => 0),
      ]).timeout(const Duration(seconds: 7));
      if (results[0] != 0) throw StateError('Windows hardware query failed');
      return HostHardware.fromJson(
          jsonDecode(results[1] as String) as Map<String, dynamic>);
    } on TimeoutException {
      process.kill();
      rethrow;
    }
  }
}
