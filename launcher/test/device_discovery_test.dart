import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/app.dart';
import 'package:lulu_remote/screens/add_device_screen.dart';
import 'package:lulu_remote/services/mesh_status_service.dart';

void main() {
  testWidgets('selecting a discovered computer only fills the add form',
      (tester) async {
    final discovery = Completer<List<MeshComputer>>();
    await tester.pumpWidget(MaterialApp(
      theme: LuluTheme.darkTheme,
      home: AddDeviceScreen(findComputers: () => discovery.future),
    ));
    await tester.tap(find.text('发现 Tailscale 电脑'));
    await tester.pump();
    expect(find.text('正在查找…'), findsOneWidget);
    discovery.complete([const MeshComputer('lab-pc', '100.90.8.4')]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('lab-pc'));
    await tester.pumpAndSettle();
    expect(find.byType(AddDeviceScreen), findsOneWidget);
    expect(find.text('lab-pc'), findsOneWidget);
    expect(find.text('100.90.8.4'), findsOneWidget);
    expect(find.text('已填入地址，请确认后保存。'), findsOneWidget);
  });
}
