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

  test('a later probe detects a host that has finished starting', () async {
    var ready = false;
    server.listen((request) {
      expect(request.uri.path, '/serverinfo');
      request.response.statusCode =
          ready ? HttpStatus.ok : HttpStatus.serviceUnavailable;
      request.response.close();
    });

    expect(await mesh.check(device), HostStatus.unreachable);
    ready = true;
    expect(await mesh.check(device), HostStatus.online);
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
}
