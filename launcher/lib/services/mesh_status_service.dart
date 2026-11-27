import 'dart:convert';
import 'dart:io';

import '../models/device.dart';

/// Online/offline check for one host.
///
/// This checks reachability of Sunshine's NVHTTP endpoint over the mesh,
/// not the VPN daemon state: a host can be on Tailscale and still refuse
/// pairing because Sunshine is not running or the firewall blocks it.
/// The setup checklist (not this dot) is what catches that.
///
/// NOTE: /serverinfo over plaintext HTTP on 47989 is unauthenticated
/// by design (GameStream discovery). No secret is sent here.
class MeshStatusService {
  Future<HostStatus> check(Device device) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(
        Uri.parse('${device.nvhttpBase}/serverinfo?uniqueid=lulu-probe'),
      );
      final response = await request.close().timeout(
            const Duration(seconds: 3),
          );
      await response.drain<void>();
      return response.statusCode == 200
          ? HostStatus.online
          : HostStatus.unreachable;
    } on SocketException {
      return HostStatus.offline;
    } on HttpException {
      return HostStatus.unreachable;
    } catch (_) {
      return HostStatus.offline;
    } finally {
      client.close();
    }
  }

  Future<bool> isLocalAddress(String host) async {
    final normalized = host.trim().toLowerCase();
    final address = InternetAddress.tryParse(normalized);
    if (normalized == 'localhost' ||
        normalized == Platform.localHostname.toLowerCase() ||
        address?.isLoopback == true) {
      return true;
    }
    if (address == null) return false;
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: true);
      if (interfaces
          .any((interface) => interface.addresses.contains(address))) {
        return true;
      }
    } on SocketException {
      // A Tailscale address can still be verified through its CLI on Windows.
    }
    return address.address == await localMeshAddress();
  }

  Future<bool?> isTailscaleConnected() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run(
        _tailscaleCommand(),
        ['status', '--json'],
      ).timeout(const Duration(seconds: 4));
      final detail = jsonDecode(result.stdout as String);
      final state = detail is Map ? detail['BackendState'] : null;
      return state is String ? state == 'Running' : null;
    } on Exception {
      return null;
    }
  }

  /// Checks whether the Tailscale tunnel answers independently of the app port.
  Future<bool> answersTailscalePing(String address) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run(
        _tailscaleCommand(),
        ['ping', '--c', '1', '--timeout', '2s', address],
      ).timeout(const Duration(seconds: 4));
      return result.exitCode == 0;
    } on Exception {
      return false;
    }
  }

  /// Best-effort local mesh address (Windows: `tailscale ip`, else null).
  /// Used only for the footer hint; never for connecting.
  Future<String?> localMeshAddress() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run(
        _tailscaleCommand(),
        ['ip', '-4'],
      ).timeout(const Duration(seconds: 4));
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split('\n').first.trim();
      }
    } catch (_) {
      // Tailscale CLI absent — footer shows "未知" instead.
    }
    return null;
  }

  String _tailscaleCommand() {
    final installed = File(
      '${Platform.environment['ProgramFiles']}\\Tailscale\\tailscale.exe',
    );
    return installed.existsSync() ? installed.path : 'tailscale';
  }
}

enum HostStatus { online, offline, unreachable }

extension HostStatusLabel on HostStatus {
  String get label => switch (this) {
        HostStatus.online => '在线',
        HostStatus.offline => '离线',
        HostStatus.unreachable => '不可达',
      };
}
