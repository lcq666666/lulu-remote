import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/file_transfer_service.dart';
import 'package:lulu_remote/services/power_service.dart';
import 'package:lulu_remote/widgets/power_settings.dart';

void main() {
  testWidgets('requires confirmation and explains stream disconnection',
      (tester) async {
    final code = newTransferCode();
    var finished = false;
    String? submitted;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  onPressed: () async {
                    submitted = await showDialog<String>(
                        context: context,
                        builder: (_) => const PowerConfirmation(
                            action: PowerAction.restart,
                            deviceName: '实验室电脑',
                            code: ''));
                    finished = true;
                  },
                  child: const Text('选重启'),
                )))));
    await tester.tap(find.text('选重启'));
    await tester.pumpAndSettle();
    expect(find.textContaining('会断开'), findsOneWidget);
    await tester.tap(find.text('确认重启'));
    await tester.pumpAndSettle();
    expect(finished, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(submitted, isNull);
    await tester.tap(find.text('选重启'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), code);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重启'));
    await tester.pumpAndSettle();
    expect(submitted == code, isTrue);
  });
}
