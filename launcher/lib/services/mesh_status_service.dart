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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
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

  /// Best-effort local mesh address (Windows: `tailscale ip`, else null).
  /// Used only for the footer hint; never for connecting.
  Future<String?> localMeshAddress() async {
    if (!Platform.isWindows) return null;
    try {
      final installed = File(
        '${Platform.environment['ProgramFiles']}\\Tailscale\\tailscale.exe',
      );
      final result = await Process.run(
        installed.existsSync() ? installed.path : 'tailscale',
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
}

enum HostStatus { online, offline, unreachable }

extension HostStatusLabel on HostStatus {
  String get label => switch (this) {
        HostStatus.online => '在线',
        HostStatus.offline => '离线',
        HostStatus.unreachable => '不可达',
      };
}
