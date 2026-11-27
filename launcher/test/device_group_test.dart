import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh store restores two groups and the nickname', () async {
    SharedPreferences.setMockInitialValues({});
    final lab = Device(
        id: 'lab',
        name: 'LAB-PC',
        meshAddress: '100.64.0.10',
        wakeMac: '00:11:22:33:44:55',
        wakeRelayAddress: '100.64.0.40',
        group: '实验室',
        nickname: '工作站');
    final home = Device(
        id: 'home', name: 'HOME-PC', meshAddress: '100.64.0.20', group: '家里');
    await DeviceStore().save([lab, home]);
    final prefs = await SharedPreferences.getInstance();
    SharedPreferences.setMockInitialValues(
        {'lulu_devices_v1': prefs.getString('lulu_devices_v1')!});
    final restored = await DeviceStore().load();
    expect(restored.map((device) => device.group), ['实验室', '家里']);
    expect(restored.map((device) => device.displayName), ['工作站', 'HOME-PC']);
    expect(restored.first.copyWith(paired: true).displayName, '工作站');
    expect(
        restored.first.copyWith(paired: true).wakeRelayAddress, '100.64.0.40');
    expect(restored.last.wakeRelayAddress, isNull);
  });

  test('old entries without metadata still load', () {
    final legacy = Device.fromJson(
        {'id': 'old', 'name': 'OLD', 'meshAddress': '100.64.0.30'});
    expect(legacy.group, isEmpty);
    expect(legacy.displayName, 'OLD');
  });
}
