import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/moonlight_launcher.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lulu.remote/launch');
  final launcher = MoonlightLauncher();
  tearDown(() =>
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('Android can open Moonlight without a launcher pairing', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'openMoonlight');
      expect(call.arguments, isNull);
      return false;
    });
    expect(await launcher.openAndroid(), isFalse);
  });

  test('Android shortcut works with an observed UUID and optional app ID',
      () async {
    const uuid = '29a7a2ce-3c38-462f-b94a-350c87f58d8b';
    final device = Device(id: '1', name: 'Office', meshAddress: 'office.mesh');
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return true;
    });
    expect(await launcher.launchAndroidShortcut(device, uuid), isTrue);
    device.appId = 123;
    expect(await launcher.launchAndroidShortcut(device, uuid), isTrue);
    expect(
        calls.map((call) => call.method), ['launchShortcut', 'launchShortcut']);
    expect(calls[0].arguments, {'uuid': uuid, 'appName': 'Desktop'});
    expect(
        calls[1].arguments, {'uuid': uuid, 'appName': 'Desktop', 'appId': 123});
  });

  test('Moonlight uses the existing address on default port', () {
    final device = Device(id: '1', name: 'Office', meshAddress: 'office.mesh');
    expect(WindowsMoonlight.endpoint(device), 'office.mesh');
  });

  test('Moonlight connects using the saved custom Sunshine port', () {
    final device = Device(
      id: '1',
      name: 'Office',
      meshAddress: '100.64.0.23',
      sunshinePort: 48123,
    );
    expect(WindowsMoonlight.endpoint(device), '100.64.0.23:48123');
  });
}
