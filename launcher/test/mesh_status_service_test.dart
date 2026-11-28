import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/mesh_status_service.dart';

void main() {
  late HttpServer server;
  late Device device;
  final mesh = MeshStatusService();

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    device = Device(
      id: 'test-host',
      name: 'Test host',
      meshAddress: server.address.address,
      sunshinePort: server.port,
    );
  });

  tearDown(() => server.close(force: true));

  test('Tailscale whois matches only an exact node address', () {
    String? resolve(String ip, List<String> prefixes,
            {String name = 'lab-pc.private.test.'}) =>
        MeshStatusService.parseTailscalePeerName(
            jsonEncode({
              'Node': {'Addresses': prefixes, 'Name': name}
            }),
            InternetAddress(ip));
    expect(resolve('100.90.8.4', ['100.90.8.4/32']), 'lab-pc');
    expect(resolve('::ffff:100.90.8.4', ['100.90.8.4/32']), 'lab-pc');
    expect(resolve('fd7a:115c:a1e0::11', ['fd7a:115c:a1e0:0:0:0:0:11/128']),
        'lab-pc');
    expect(resolve('100.90.8.4', ['100.90.8.0/24']), isNull);
    expect(resolve('100.90.8.4', ['100.90.8.5/32']), isNull);
    expect(
        resolve('100.90.8.4', ['100.90.8.4/32'], name: 'spaces here'), isNull);
    expect(resolve('192.168.1.4', ['192.168.1.4/32']), isNull);
  });

  test('Tailscale discovery excludes self, saved and offline peers', () async {
    final service = _DiscoveryMesh(
        jsonEncode({
          'BackendState': 'Running',
          'Self': {
            'TailscaleIPs': ['100.64.0.1']
          },
          'Peer': {
            'self': _peer('100.64.0.1'),
            'saved': _peer('100.64.0.2'),
            'offline': _peer('100.64.0.3', online: false),
            'web-only': _peer('100.64.0.4', name: 'app-server.private.test.'),
            'sunshine': _peer('100.64.0.5', name: 'lab-pc.private.test.'),
            'duplicate': _peer('100.64.0.5'),
            'not-overlay': _peer('192.0.2.1'),
          },
        }),
        {'100.64.0.5'});
    final found = await service
        .discoverTailscaleComputers(savedAddresses: {'100.64.0.2'});
    expect(service.probed, ['100.64.0.4', '100.64.0.5']);
    expect(found.single.address, '100.64.0.5');
    expect(found.single.name, 'lab-pc');
  });

  test('Tailscale discovery bounds work and rejects a disconnected mesh',
      () async {
    final inactive = _DiscoveryMesh('{"BackendState":"Stopped"}', {});
    await expectLater(
        inactive.discoverTailscaleComputers(), throwsFormatException);
    expect(inactive.probed, isEmpty);
    final active = _DiscoveryMesh(
        jsonEncode({
          'BackendState': 'Running',
          'TailscaleIPs': ['100.64.0.1'],
          'Peer': {
            for (var i = 2; i < 50; i++) '$i': _peer('100.64.0.$i'),
          },
        }),
        {});
    expect(await active.discoverTailscaleComputers(), isEmpty);
    expect(active.probed, hasLength(MeshStatusService.discoveryLimit));
  });

  test('oversize Sunshine status is rejected', () async {
    server.listen((request) {
      request.response.write('<root status_code="200"><appversion>7.1'
          '${' ' * (64 * 1024)}</appversion></root>');
      request.response.close();
    });
    expect(await mesh.check(device), HostStatus.unreachable);
  });

  test('a later probe detects a host that has finished starting', () async {
    var ready = false;
    server.listen((request) {
      expect(request.uri.path, '/serverinfo');
      request.response.statusCode =
          ready ? HttpStatus.ok : HttpStatus.serviceUnavailable;
      if (ready) {
        request.response.write(
            '<root status_code="200"><appversion>7.1</appversion></root>');
      }
      request.response.close();
    });

    expect(await mesh.check(device), HostStatus.unreachable);
    ready = true;
    expect(await mesh.check(device), HostStatus.online);
  });

  test('discovery exposes only a valid Sunshine UUID for a shortcut', () async {
    const uuid = '29a7a2ce-3c38-462f-b94a-350c87f58d8b';
    var uniqueId = '<uniqueid>$uuid</uniqueid>';
    server.listen((request) {
      request.response.write(
          '<root status_code="200"><appversion>7.1</appversion>$uniqueId</root>');
      request.response.close();
    });
    expect((await mesh.diagnose(device)).hostUuid, uuid);
    for (final element in ['', '<uniqueid>bad-id</uniqueid>']) {
      uniqueId = element;
      final result = await mesh.diagnose(device);
      expect(result.status, HostStatus.online);
      expect(result.hostUuid, isNull);
    }
  });

  test('a redirected status request does not mark the host online', () async {
    server.listen((request) {
      if (request.uri.path == '/serverinfo') {
        request.response.redirect(Uri.parse('/other'));
      } else {
        request.response.close();
      }
    });

    expect(await mesh.check(device), HostStatus.unreachable);
  });
  test('HTTP 200 from a different service does not mark the host online',
      () async {
    server.listen((request) {
      request.response.write('<html>Not Sunshine</html>');
      request.response.close();
    });

    final result = await mesh.diagnose(device);
    expect(result.status, HostStatus.unreachable);
    expect(result.detail, contains('连接端口'));
  });
}

Map<String, Object> _peer(String ip, {bool online = true, String name = ''}) =>
    {
      'Online': online,
      'TailscaleIPs': [ip],
      'DNSName': name
    };

class _DiscoveryMesh extends MeshStatusService {
  _DiscoveryMesh(this.payload, this.online);
  final String payload;
  final Set<String> online;
  final probed = <String>[];

  @override
  Future<String?> readTailscaleDiscoveryStatus() async => payload;

  @override
  Future<HostStatus> check(Device device) async {
    probed.add(device.meshAddress);
    expect(device.sunshinePort, 47989);
    return online.contains(device.meshAddress)
        ? HostStatus.online
        : HostStatus.offline;
  }
}
