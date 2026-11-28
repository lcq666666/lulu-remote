import 'dart:async';
import 'dart:convert';
import 'dart:io';

class HostDiskVolume {
  const HostDiskVolume({
    required this.drive,
    required this.totalBytes,
    required this.freeBytes,
    required this.system,
  });

  final String drive;
  final int totalBytes;
  final int freeBytes;
  final bool system;

  static final _drivePattern = RegExp(r'^[A-Z]:$');

  factory HostDiskVolume._fromJson(Map<String, dynamic> json) {
    final drive = json['drive'];
    final system = json['system'];
    final total = HostHardware._bytes(json, 'totalBytes');
    final free = HostHardware._bytes(json, 'freeBytes');
    if (drive is! String ||
        !_drivePattern.hasMatch(drive) ||
        system is! bool ||
        free > total) {
      throw const FormatException('Invalid disk volume');
    }
    return HostDiskVolume(
        drive: drive, totalBytes: total, freeBytes: free, system: system);
  }

  Map<String, Object> _toJson() => {
        'drive': drive,
        'totalBytes': totalBytes,
        'freeBytes': freeBytes,
        'system': system,
      };
}

class HostHardware {
  const HostHardware(
      {required this.cpu,
      required this.ramBytes,
      required this.diskBytes,
      required this.diskFreeBytes,
      required this.os,
      this.volumes = const []});

  factory HostHardware.fromJson(Map<String, dynamic> json) {
    // Older peers use these two fields for the system drive only.
    final total = _bytes(json, 'diskBytes');
    final free = _bytes(json, 'diskFreeBytes');
    if (free > total) throw const FormatException('Invalid storage size');
    final volumes = _readVolumes(json['volumes']);
    if (volumes.isNotEmpty &&
        (!volumes.first.system ||
            volumes.first.totalBytes != total ||
            volumes.first.freeBytes != free ||
            volumes.skip(1).any((volume) => volume.system))) {
      throw const FormatException('Invalid system volume');
    }
    return HostHardware(
        cpu: _text(json, 'cpu'),
        os: _text(json, 'os'),
        ramBytes: _bytes(json, 'ramBytes'),
        diskBytes: total,
        diskFreeBytes: free,
        volumes: volumes);
  }

  final String cpu;
  final int ramBytes;
  final int diskBytes;
  final int diskFreeBytes;
  final String os;
  final List<HostDiskVolume> volumes;

  static List<HostDiskVolume> _readVolumes(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 26) {
      throw const FormatException('Invalid disk volume list');
    }
    final volumes = <HostDiskVolume>[];
    final drives = <String>{};
    for (final row in raw) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Invalid disk volume');
      }
      final volume = HostDiskVolume._fromJson(row);
      if (!drives.add(volume.drive)) {
        throw const FormatException('Duplicate disk volume');
      }
      volumes.add(volume);
    }
    volumes.sort((left, right) => left.system != right.system
        ? (left.system ? -1 : 1)
        : left.drive.compareTo(right.drive));
    return List.unmodifiable(volumes);
  }

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
        'os': os,
        if (volumes.isNotEmpty)
          'volumes': volumes.map((volume) => volume._toJson()).toList(),
      };

  static String _gib(int bytes) =>
      '${(bytes / (1 << 30)).toStringAsFixed(1)} GiB';

  static String _capacity(int free, int total) =>
      '${_gib(free)} 可用 / ${_gib(total)}';

  String get summary => [
        'CPU：$cpu',
        '内存：${_gib(ramBytes)}',
        if (volumes.isEmpty)
          '系统盘：${_capacity(diskFreeBytes, diskBytes)}'
        else
          for (final volume in volumes)
            '${volume.system ? '系统盘' : '本地盘'} ${volume.drive}  ${_capacity(volume.freeBytes, volume.totalBytes)}',
        '系统：$os',
      ].join('\n');

  static const _query = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$system = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$processors = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() } | Select-Object -Unique)
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
    Where-Object { $_.DeviceID -match '^[A-Z]:$' -and $_.Size -gt 0 -and $null -ne $_.FreeSpace })
$disk = $disks | Where-Object DeviceID -eq $os.SystemDrive | Select-Object -First 1
if (!$disk -or !$processors -or !$system.TotalPhysicalMemory) { exit 1 }
$volumes = @($disks | ForEach-Object {
    @{ drive = $_.DeviceID.ToUpperInvariant(); totalBytes = $_.Size;
       freeBytes = $_.FreeSpace; system = ($_.DeviceID -eq $os.SystemDrive) }
})
@{ cpu = $processors -join ' / '; ramBytes = $system.TotalPhysicalMemory;
   diskBytes = $disk.Size; diskFreeBytes = $disk.FreeSpace;
   os = "$($os.Caption.Trim()) ($($os.Version))"; volumes = $volumes } | ConvertTo-Json -Depth 3 -Compress
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
