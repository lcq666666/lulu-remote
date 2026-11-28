import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

String activationDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

class MachineFingerprint {
  MachineFingerprint(this.platform, Iterable<String> parts)
      : parts = List.unmodifiable(parts);

  factory MachineFingerprint.fromIdentifiers(
      String platform, List<String?> identifiers) {
    return MachineFingerprint(platform, [
      for (var index = 0; index < identifiers.length; index++)
        if (_usable(identifiers[index]))
          activationDigest('lulu-device-v1:$platform:$index:'
              '${identifiers[index]!.trim().toLowerCase()}')
        else
          '',
    ]);
  }

  static bool _usable(String? value) {
    final normalized = value?.trim().toLowerCase() ?? '';
    return normalized.isNotEmpty &&
        !const {
          'to be filled by o.e.m.',
          'default string',
          'unknown',
          'none',
          'not specified',
          'system serial number',
          'not applicable',
          '123456789',
          '0123456789',
        }.contains(normalized) &&
        !RegExp(r'^(0+|f+|0{8}-0{4}-0{4}-0{4}-0{12})$').hasMatch(normalized);
  }

  final String platform;
  final List<String> parts;
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

  bool get valid =>
      (platform == 'windows' && parts.length == 3 ||
          platform == 'android' && parts.length == 1) &&
      parts.every((part) => part.isEmpty || _hashPattern.hasMatch(part)) &&
      parts.where((part) => part.isNotEmpty).length >=
          (platform == 'windows' ? 2 : 1);

  String get hash => activationDigest('$platform:${parts.join(':')}');

  String get code {
    final short = hash.substring(0, 16).toUpperCase();
    return [for (var i = 0; i < 16; i += 4) short.substring(i, i + 4)]
        .join('-');
  }

  bool matches(MachineFingerprint other) {
    if (!valid || !other.valid || platform != other.platform) return false;
    var matches = 0;
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty && parts[i] == other.parts[i]) matches++;
    }
    return matches >= (platform == 'windows' ? 2 : 1);
  }

  Map<String, Object> toJson() => {'platform': platform, 'parts': parts};
}

class MachineCodeService {
  const MachineCodeService();
  static const _channel = MethodChannel('lulu.remote/activation');

  Future<MachineFingerprint> read() async {
    if (Platform.isAndroid) {
      final id = await _channel.invokeMethod<String>('readAndroidId');
      return MachineFingerprint.fromIdentifiers('android', [id]);
    }
    if (!Platform.isWindows) throw UnsupportedError('Unsupported platform');
    // Look up the physical disk backing the running Windows volume. An
    // extra data disk must not replace the system disk in the fingerprint.
    const script = r'''
$board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
$volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
$partition = $volume | Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue | Select-Object -First 1
$disk = $partition | Get-CimAssociatedInstance -ResultClassName Win32_DiskDrive -ErrorAction SilentlyContinue | Select-Object -First 1
$guid = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction SilentlyContinue
[Console]::OutputEncoding = [Text.Encoding]::UTF8
@{board=$board.SerialNumber;disk=$disk.SerialNumber;guid=$guid} | ConvertTo-Json -Compress
''';
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final process = await Process.start(
        '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', script]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    final result = await (() async {
      final code = await process.exitCode;
      await errors;
      final text = await output;
      if (code != 0) throw StateError('Machine information unavailable');
      return jsonDecode(text) as Map<String, dynamic>;
    })()
        .timeout(const Duration(seconds: 10), onTimeout: () {
      process.kill();
      throw TimeoutException('Machine information unavailable');
    });
    return MachineFingerprint.fromIdentifiers('windows', [
      result['board'] as String?,
      result['disk'] as String?,
      result['guid'] as String?,
    ]);
  }
}
