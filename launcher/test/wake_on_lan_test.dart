import 'dart:async';

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
