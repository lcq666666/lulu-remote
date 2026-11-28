import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/host_setup_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('lulu.remote/launch');
  final service = HostSetupService();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android checks distinguish installed apps from missing apps', () async {
    var hasTailscale = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'androidConnectionApps');
      expect(call.arguments, isNull);
      return {'moonlight': true, 'tailscale': hasTailscale};
    });
    final before = await service.runAndroidChecks();
    expect(before.map((app) => app.ok), [true, false]);
    expect(before.first.detail, contains('仍需配对'));
    expect(before.last.fixUrl?.queryParameters['id'], 'com.tailscale.ipn');
    hasTailscale = true;
    final after = await service.runAndroidChecks();
    expect(after.map((app) => app.ok), [true, true]);
    expect(after.last.detail, contains('请在其中确认组网已连接'));
  });

  test('Android checks report unknown for a missing or failing handler',
      () async {
    expect(
        (await service.runAndroidChecks()).map((app) => app.ok), [null, null]);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'probe_failed');
    });
    expect(
        (await service.runAndroidChecks()).map((app) => app.ok), [null, null]);
  });

  test('Android checks keep independent component results on a partial reply',
      () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => {'moonlight': false});
    final rows = await service.runAndroidChecks();
    expect(rows.map((app) => app.ok), [false, null]);
    expect(rows.first.fixUrl?.queryParameters['id'], 'com.limelight');
    expect(rows.last.detail, contains('暂时无法检测'));
  });
}
