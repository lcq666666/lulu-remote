import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:lulu_pairing_worker/src/device.dart';
import 'package:lulu_pairing_worker/src/sunshine_pin_api.dart';

class _LocalDevice extends Device {
  _LocalDevice(int port)
      : super(
            id: 'test', name: 'Test', meshAddress: '127.0.0.1', webPort: port);

  @override
  String get webBase => 'http://127.0.0.1:$webPort';
}

void main() {
  test('submits the matching pending request and requires acceptance',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const pairingId = '0123456789abcdef0123456789abcdef';
    final posts = <({String? token, Object? payload})>[];
    final events = <String>[];
    server.listen((request) async {
      final Object response;
      if (request.method == 'POST') {
        events.add('posted');
        posts.add((
          token: request.headers.value('X-CSRF-Token'),
          payload: jsonDecode(await utf8.decoder.bind(request).join()),
        ));
        response = {'status': posts.length == 1};
      } else if (request.uri.path == '/api/csrf-token') {
        events.add('csrf');
        response = {'csrf_token': 'test-token'};
      } else {
        response = {
          'pairings': [
            {'id': 'fedcba9876543210fedcba9876543210', 'name': 'other'},
            {'id': pairingId, 'name': 'LULU-this-request'},
          ],
        };
      }
      request.response.write(jsonEncode(response));
      await request.response.close();
    });

    Future<void> submit() => SunshinePinApi().submitPin(
          device: _LocalDevice(server.port),
          pin: '0123',
          adminUser: 'test',
          adminPassword: 'test',
          requestName: 'LULU-this-request',
          onRequestFound: () => events.add('found'),
        );

    await submit();
    expect(events, ['found', 'csrf', 'posted']);
    expect(posts.single.token, 'test-token');
    expect(posts.single.payload, {
      'pin': '0123',
      'name': 'LULU',
      'pairing_id': pairingId,
    });
    await expectLater(submit(), throwsA(isA<HttpException>()));
  });

  test('distinguishes rejected credentials from blocked network access',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var status = HttpStatus.unauthorized;
    server.listen((request) async {
      request.response.statusCode = status;
      await request.response.close();
    });
    final api = SunshinePinApi();

    Future<void> verify() => api.verifyAccount(
          device: _LocalDevice(server.port),
          adminUser: 'test',
          adminPassword: 'test',
        );

    await expectLater(
      verify(),
      throwsA(isA<HttpException>().having(
        (error) => error.message,
        'message',
        contains('账号或密码'),
      )),
    );
    status = HttpStatus.forbidden;
    await expectLater(
      verify(),
      throwsA(isA<HttpException>().having(
        (error) => error.message,
        'message',
        contains('访问范围'),
      )),
    );
  });
}
