import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

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
  static const selfAddressMessage =
      '这个地址是你本机，配对请求会发给自己，请填对方电脑在 LULU「让别人连接我」里显示的地址。';

  Future<List<LocalAddress>> localAddresses() async {
    final meshFuture = localMeshAddress();
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    );
    final meshAddress = await meshFuture;
    final addresses = <String, LocalAddress>{};
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      for (final ip in interface.addresses) {
        final network = switch (name) {
          _ when name.contains('tailscale') => NetworkKind.tailscale,
          _ when name.contains('natpierce') || name.contains('皎月') =>
            NetworkKind.natpierce,
          _ when name.contains('zerotier') => NetworkKind.zerotier,
          _ => null,
        };
        addresses[ip.address] = LocalAddress(ip.address, network);
      }
    }
    if (meshAddress != null && meshAddress.isNotEmpty) {
      addresses[meshAddress] = LocalAddress(meshAddress, NetworkKind.tailscale);
    }
    return addresses.values.toList();
  }

  bool isLocalAddress(String host, Iterable<LocalAddress> local) {
    final name = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final ip = InternetAddress.tryParse(name);
    return name == 'localhost' ||
        name == Platform.localHostname.toLowerCase() ||
        ip?.isLoopback == true ||
        local.any((entry) => entry.address == ip?.address);
  }

  static bool connectionRefused(SocketException error) =>
      const {10061, 1225, 111, 61}.contains(error.osError?.errorCode);

  Future<void> verifyLocalHost() async {
    const timeout = Duration(seconds: 3);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:47989/serverinfo'));
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('本机远程服务返回 HTTP ${response.statusCode}（47989）。');
      }
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      final info = XmlDocument.parse(body).rootElement;
      if (info.name.local != 'root' || info.getElement('appversion') == null) {
        throw StateError('本机连接端口有响应，但没有返回 Sunshine 的设备信息。');
      }
    } on SocketException catch (error) {
      throw StateError(connectionRefused(error)
          ? '本机远程服务拒绝连接（47989）。请确认 Sunshine 服务已启动。'
          : '无法访问本机远程服务（47989）。系统错误 ${error.osError?.errorCode ?? error.message}。');
    } on TimeoutException {
      throw StateError('本机远程服务在 3 秒内没有回应（47989）。');
    } on FormatException {
      throw StateError('本机连接端口返回了无法识别的设备信息（47989）。');
    } on XmlException {
      throw StateError('本机连接端口返回了无法识别的设备信息（47989）。');
    } on HttpException {
      throw StateError('本机连接端口未完成 HTTP 响应（47989）。');
    } finally {
      client.close(force: true);
    }
  }

  Future<HostStatus> check(Device device) async =>
      (await diagnose(device)).status;

  Future<({HostStatus status, String detail, String? hostUuid})> diagnose(
      Device device) async {
    const timeout = Duration(seconds: 4);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final uri = Uri(
          scheme: 'http',
          host: device.meshAddress,
          port: device.sunshinePort,
          path: '/serverinfo',
        );
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          return (
            status: HostStatus.unreachable,
            hostUuid: null,
            detail: '远程服务返回 HTTP ${response.statusCode}。',
          );
        }
        final body = await response.transform(utf8.decoder).join();
        final info = XmlDocument.parse(body).rootElement;
        if (info.name.local != 'root' ||
            info.getAttribute('status_code') != '200' ||
            info.getElement('appversion') == null) {
          throw const FormatException('Invalid serverinfo');
        }
        final reportedUuid = info.getElement('uniqueid')?.innerText.trim();
        final validUuid = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          caseSensitive: false,
        );
        return (
          status: HostStatus.online,
          detail: '',
          hostUuid: reportedUuid != null && validUuid.hasMatch(reportedUuid)
              ? reportedUuid
              : null,
        );
      })()
          .timeout(timeout);
    } on SocketException catch (error) {
      return connectionRefused(error)
          ? (
              status: HostStatus.offline,
              hostUuid: null,
              detail: '连接被拒绝，请确认对方已开启远程控制。'
            )
          : (
              status: HostStatus.unreachable,
              hostUuid: null,
              detail: '网络无法连接，请核对地址和双方的组网状态。'
            );
    } on TimeoutException {
      return (
        status: HostStatus.unreachable,
        hostUuid: null,
        detail: '远程服务在 4 秒内没有回应，请确认对方已开机，双方组网已连接。'
      );
    } on HttpException {
      return (
        status: HostStatus.unreachable,
        hostUuid: null,
        detail: '未收到完整的远程服务响应，请核对地址和连接端口。'
      );
    } on FormatException {
      return (
        status: HostStatus.unreachable,
        hostUuid: null,
        detail: '该端口没有返回 Sunshine 设备信息，请核对连接端口。'
      );
    } on XmlException {
      return (
        status: HostStatus.unreachable,
        hostUuid: null,
        detail: '该端口没有返回 Sunshine 设备信息，请核对连接端口。'
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<bool?> tailscaleConnected() async {
    if (!Platform.isWindows) return null;
    try {
      final status =
          await Process.run(_tailscaleCommand(), ['status', '--json'])
              .timeout(const Duration(seconds: 4));
      final json = jsonDecode(status.stdout as String);
      final state = json is Map ? json['BackendState'] : null;
      return state is String ? state == 'Running' : null;
    } on Exception {
      return null;
    }
  }

  Future<String?> tailscalePeerName(InternetAddress address) async {
    final peer = _normalizePeer(address);
    if (!Platform.isWindows || !_isTailscaleAddress(peer)) return null;
    try {
      final result = await Process.run(
        _tailscaleCommand(),
        ['whois', '--json', peer.address],
      ).timeout(const Duration(seconds: 3));
      return result.exitCode == 0
          ? parseTailscalePeerName(result.stdout.toString(), peer)
          : null;
    } on Exception {
      return null;
    }
  }

  static InternetAddress _normalizePeer(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv6 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return InternetAddress.fromRawAddress(bytes.sublist(12));
    }
    return address;
  }

  static bool _isTailscaleAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 100 && (bytes[1] & 0xc0) == 0x40;
    }
    const prefix = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0];
    return prefix
        .asMap()
        .entries
        .every((pair) => bytes[pair.key] == pair.value);
  }

  static String? parseTailscalePeerName(
      String payload, InternetAddress address) {
    final peer = _normalizePeer(address);
    if (!_isTailscaleAddress(peer)) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['Node'] is! Map) return null;
    final node = decoded['Node'] as Map;
    final addresses = node['Addresses'];
    final name = node['Name'];
    if (addresses is! List || name is! String) return null;
    final fullMask = peer.type == InternetAddressType.IPv4 ? '32' : '128';
    final ownAddress = addresses.whereType<String>().any((address) {
      final parts = address.split('/');
      return parts.length == 2 &&
          parts[1] == fullMask &&
          InternetAddress.tryParse(parts[0]) == peer;
    });
    if (!ownAddress) return null;
    final host = name.split('.').first;
    return RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$').hasMatch(host)
        ? host
        : null;
  }

  String _tailscaleCommand() {
    final installed = File(
      '${Platform.environment['ProgramFiles']}\\Tailscale\\tailscale.exe',
    );
    return installed.existsSync() ? installed.path : 'tailscale';
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
}

class LocalAddress {
  const LocalAddress(this.address, this.network);

  final String address;
  final NetworkKind? network;

  String get label => network?.label ?? '局域网';
}

enum HostStatus { online, offline, unreachable }

extension HostStatusLabel on HostStatus {
  String get label => switch (this) {
        HostStatus.online => '在线',
        HostStatus.offline => '离线',
        HostStatus.unreachable => '不可达',
      };
}
