import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/wake_on_lan.dart';
import 'package:lulu_remote/services/file_transfer_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('relay targets are opt-in, normalized, persisted and removable',
      () async {
    SharedPreferences.setMockInitialValues({});
    final host = FileTransferHost.instance;
    expect(await host.wakeTargets(), isEmpty);
    await expectLater(host.setWakeTargets(['invalid']), throwsFormatException);
    await host.setWakeTargets(['00-aa-22-33-44-55', '00:AA:22:33:44:55']);
    await (await SharedPreferences.getInstance()).reload();
    expect(await host.wakeTargets(), {'00:AA:22:33:44:55'});
    await host.setWakeTargets([]);
    expect(await host.wakeTargets(), isEmpty);
  });

  test('magic packet has six FF bytes and sixteen copies of the MAC', () {
    final packet = WakeOnLan.packet('00-11-22-aa-bb-cc');
    expect(packet, hasLength(102));
    expect(packet.take(6), List.filled(6, 255));
    for (var index = 6; index < packet.length; index += 6) {
      expect(packet.sublist(index, index + 6), [0, 17, 34, 170, 187, 204]);
    }
    expect(() => WakeOnLan.packet('ff:ff:ff:ff:ff:ff'), throwsFormatException);
  });

  test('computes subnet broadcast from the address and prefix', () {
    expect(WakeOnLan.routeFor('192.168.12.99', 24)?.broadcast.address,
        '192.168.12.255');
    expect(WakeOnLan.routeFor('10.18.16.31', 20)?.broadcast.address,
        '10.18.31.255');
    expect(WakeOnLan.routeFor('192.168.12.99', 27)?.broadcast.address,
        '192.168.12.127');
    expect(WakeOnLan.routeFor('192.168.12.9', 30)?.broadcast.address,
        '192.168.12.11');
    for (final invalid in [
      ('192.168.12.9', 31),
      ('192.168.12.7', 0),
      ('192.168.12.255', 24),
      ('127.0.0.1', 8),
      ('239.0.0.1', 24),
      ('::1', 24),
      ('0.0.0.0', 8),
      ('not an address', 24),
    ]) {
      expect(WakeOnLan.routeFor(invalid.$1, invalid.$2), isNull);
    }
  });

  test('tries distinct interface routes even if one adapter fails', () async {
    final wifi = WakeOnLan.routeFor('192.168.2.5', 24)!;
    final wired = WakeOnLan.routeFor('192.168.3.10', 24)!;
    final sent = <LanWakeRoute>[];
    final packet = WakeOnLan.packet('00:11:22:33:44:55');
    await WakeOnLan.sendViaRoutes(packet, [wifi, wired, wifi],
        (payload, route) async {
      expect(payload, same(packet));
      sent.add(route);
      if (route == wifi) throw const SocketException('adapter gone');
      return true;
    });
    expect(sent, [wifi, wired]);
  });

  test('uses the original limited broadcast when no interface routes work',
      () async {
    final wifi = WakeOnLan.routeFor('192.168.2.5', 24)!;
    final packet = WakeOnLan.packet('00:11:22:33:44:55');
    final sent = <LanWakeRoute>[];
    await WakeOnLan.sendViaRoutes(packet, [wifi], (payload, route) async {
      sent.add(route);
      return route != wifi;
    });
    expect(sent, [
      wifi,
      (
        source: InternetAddress.anyIPv4,
        broadcast: InternetAddress('255.255.255.255')
      )
    ]);
    await expectLater(
        WakeOnLan.sendViaRoutes(packet, [], (_, __) async => false),
        throwsA(isA<SocketException>()));
  });

  test('stop polling when Sunshine becomes reachable', () async {
    var attempts = 0;
    expect(
        await WakeOnLan.waitForSunshine(
          probe: () async => ++attempts == 2,
          cancelled: () => false,
          interval: Duration.zero,
        ),
        WakeResult.online);
    expect(attempts, 2);
  });

  test('slow probe still times out with troubleshooting guidance', () async {
    expect(WakeOnLan.limit, const Duration(minutes: 2));
    expect(
        await WakeOnLan.waitForSunshine(
          probe: () => Completer<bool>().future,
          cancelled: () => false,
          timeout: const Duration(milliseconds: 25),
        ),
        WakeResult.timedOut);
    expect(WakeOnLan.timeoutMessage, contains('两分钟'));
    expect(WakeOnLan.timeoutMessage, contains('BIOS'));
  });
}
