import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/auto_lock_service.dart';
import 'package:lulu_remote/services/privacy_screen_service.dart';
import 'package:lulu_remote/widgets/auto_lock_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/auto_lock');
  late AutoLockService service;
  late PrivacyScreenService privacy;
  late int lockRequests;
  bool? sample;
  late bool failSample;
  late bool failLock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = AutoLockService(channel: channel);
    privacy = PrivacyScreenService(channel: channel);
    lockRequests = 0;
    sample = null;
    failSample = false;
    failLock = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'sunshineStreaming') {
        if (failSample) throw PlatformException(code: 'sample_failed');
        return sample;
      }
      if (call.method == 'lockAfterStream') {
        lockRequests++;
        if (failLock) throw PlatformException(code: 'lock_unavailable');
        return null;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() =>
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  Future<void> poll(bool? active) async {
    sample = active;
    await privacy.poll(onSample: service.onSessionSample);
  }

  test('defaults to enabled and persists changes', () async {
    expect(await AutoLockService.isEnabled(), isTrue);
    await AutoLockService.setEnabled(false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getBool('lulu_auto_lock'), isFalse);
    expect(await AutoLockService.isEnabled(), isFalse);
    await AutoLockService.setEnabled(true);
    expect(await AutoLockService.isEnabled(), isTrue);
  });

  test('startup and repeated idle or unknown samples never request a lock',
      () async {
    await poll(false);
    await poll(null);
    await poll(false);
    expect(lockRequests, 0);
  });

  test('each confirmed disconnect requests exactly one lock', () async {
    await poll(true);
    await poll(true);
    expect(lockRequests, 0);
    await poll(false);
    await poll(false);
    expect(lockRequests, 1);
    await poll(true);
    await poll(false);
    expect(lockRequests, 2);
  });

  test('setting at disconnect applies without restarting the tray', () async {
    await poll(true);
    await AutoLockService.setEnabled(false);
    await poll(false);
    await AutoLockService.setEnabled(true);
    await poll(false);
    expect(lockRequests, 0,
        reason: 'enabling does not replay an old disconnect');
    await poll(true);
    await poll(false);
    expect(lockRequests, 1);
  });

  test('query failure during a stream is not a disconnect', () async {
    await poll(true);
    await poll(null);
    failSample = true;
    await poll(false);
    expect(lockRequests, 0);
    failSample = false;
    await poll(true);
    expect(lockRequests, 0);
    await poll(false);
    expect(lockRequests, 1);
  });

  test('first confirmed idle after a failed poll can end a known session',
      () async {
    await poll(true);
    failSample = true;
    await poll(false);
    expect(lockRequests, 0);
    failSample = false;
    await poll(false);
    expect(lockRequests, 1);
  });

  test('failure to invoke the lock does not retry on idle ticks', () async {
    failLock = true;
    await poll(true);
    await poll(false);
    await poll(false);
    expect(lockRequests, 1);
  });

  testWidgets('host switch saves the setting and restores it when reopened',
      (tester) async {
    const page = MaterialApp(home: Scaffold(body: AutoLockTile()));
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    final tile = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.tap(find.text('远程结束后自动锁屏'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });
}
