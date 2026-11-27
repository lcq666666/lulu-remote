import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/app.dart';
import 'package:lulu_remote/models/device.dart';
import 'package:lulu_remote/services/mesh_status_service.dart';
import 'package:lulu_remote/widgets/device_card.dart';
import 'package:lulu_remote/widgets/pin_display.dart';
import 'package:lulu_remote/widgets/stream_screen_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Windows defaults to dark and restores the chosen appearance',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const LuluApp());
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);
    expect(find.text('画质预设'), findsOneWidget);
    expect(find.text('让别人连接我'), findsOneWidget);
    expect(find.text('添加第一台电脑'), findsOneWidget);

    await tester.tap(find.byTooltip('浅色模式'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('lulu.theme'),
        'light');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const LuluApp());
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light);

    await tester.tap(find.text('添加第一台电脑'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.text('保存电脑'));
    await tester.pumpAndSettle();
    expect(find.text('请填写对方电脑的地址和应用名。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('mobile card menu forwards the selected troubleshooting action',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var openedHelp = false;
    final device =
        Device(id: 'test-pc', name: '实验室主机', meshAddress: '192.0.2.10');
    await tester.pumpWidget(MaterialApp(
      theme: LuluTheme.darkTheme,
      home: Scaffold(
          body: Align(
        alignment: Alignment.topCenter,
        child: DeviceCard(
          device: device,
          status: HostStatus.online,
          connecting: false,
          onConnect: () {},
          mobile: true,
          onEdit: () {},
          onDelete: () {},
          onAndroidHelp: () => openedHelp = true,
        ),
      )),
    ));
    expect(tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(44));
    expect(find.text('192.0.2.10:47989'), findsOneWidget);
    await tester.tap(find.byTooltip('电脑操作'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('连接遇到问题'));
    await tester.pumpAndSettle();
    expect(openedHelp, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monitor selection returns the chosen Sunshine screen number',
      (tester) async {
    int? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              selected = await showDialog<int>(
                context: context,
                builder: (_) => const StreamScreenDialog(streaming: true),
              );
            },
            child: const Text('打开'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('屏幕 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('屏幕 2').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Ctrl+Alt+Shift+F2'), findsOneWidget);
    await tester.tap(find.text('切换屏幕'));
    await tester.pumpAndSettle();
    expect(selected, 2);
  });

  testWidgets('four PIN cells fit a narrow layout and use tabular digits',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(240, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: LuluTheme.lightTheme,
      home: const Scaffold(
          body: Padding(
        padding: EdgeInsets.all(20),
        child: PinDisplay(pin: '0375'),
      )),
    ));
    for (final digit in ['0', '3', '7', '5']) {
      final text = tester.widget<Text>(find.text(digit));
      expect(text.style?.fontFamily, 'JetBrains Mono');
      expect(text.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()));
    }
    expect(tester.takeException(), isNull);
  });
}
