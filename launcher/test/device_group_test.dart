import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/app.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/device_store.dart';
import 'package:lulu_remote/services/mesh_status_service.dart';
import 'package:lulu_remote/widgets/device_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh store restores two groups and the nickname', () async {
    SharedPreferences.setMockInitialValues({});
    final lab = Device(
        id: 'lab',
        name: 'LAB-PC',
        meshAddress: '100.64.0.10',
        group: '实验室',
        wakeRelayAddress: '100.64.0.123',
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
    final paired = restored.first.copyWith(paired: true);
    expect(paired.displayName, '工作站');
    expect(paired.wakeRelayAddress, '100.64.0.123');
    expect(groupDevices(restored).keys, ['实验室', '家里']);
    expect(groupDevices(restored)['家里']?.single.id, 'home');
  });

  testWidgets('an offline device keeps its nickname in a muted card',
      (tester) async {
    final offline = Device(
      id: 'offline',
      name: 'LAB-OLD',
      meshAddress: '100.64.0.35',
      group: '实验室',
      nickname: '离线工作站',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceCard(
          device: offline,
          status: HostStatus.offline,
          connecting: false,
          onConnect: () {},
        ),
      ),
    ));
    final nickname = find.text('离线工作站');
    expect(nickname, findsOneWidget);
    expect(tester.widget<Text>(nickname).style?.color,
        LuluTheme.of(tester.element(nickname)).muted);
    expect(find.text('LAB-OLD'), findsNothing);
    expect(groupDevices([offline])['实验室'], [offline]);
  });

  test('old entries without metadata still load', () {
    final legacy = Device.fromJson(
        {'id': 'old', 'name': 'OLD', 'meshAddress': '100.64.0.30'});
    expect(legacy.group, isEmpty);
    expect(legacy.displayName, 'OLD');
  });
}
