import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/connection_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('one completed stream produces one entry with matching timestamps',
      () async {
    final started = DateTime.utc(2026, 11, 28, 1, 10);
    var clock = started;
    final log = ConnectionLog(now: () => clock);
    await log.sessionSample(false);
    await log.sessionSample(true);
    clock = started.add(const Duration(seconds: 30));
    await log.sessionSample(null);
    await log.sessionSample(true);
    expect(await log.read(), isEmpty);
    clock = started.add(const Duration(minutes: 2));
    await log.sessionSample(false);
    await log.sessionSample(false);
    final record = (await ConnectionLog().read()).single;
    expect(record.start, started);
    expect(record.end, clock);
    expect(record.duration, const Duration(minutes: 2));
    expect(record.kind, ConnectionKind.streaming);
    expect(record.outcome, ConnectionOutcome.completed);
  });

  test('captures known pairing outcomes and safely exports UTF-8 text',
      () async {
    final log = ConnectionLog();
    log.pairingSeen('one', '实验室电脑');
    await log.pairingCompleted('one');
    log.pairingSeen('two', '便携机\n第三方字段');
    log.pairingFailed('two');
    await log.pairingSample([]);
    final rows = await log.read();
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.outcome),
        containsAll([ConnectionOutcome.completed, ConnectionOutcome.failed]));
    final temp = await Directory.systemTemp.createTemp('qg-connection-log-');
    final exported =
        File('${temp.path}${Platform.pathSeparator}connections.txt');
    addTearDown(() async {
      if (await exported.exists()) await exported.delete();
      await temp.delete();
    });
    await exported.writeAsString(ConnectionLog.exportText(rows));
    final text = await exported.readAsString();
    expect(text.split('\n'), hasLength(4));
    expect(text, contains('实验室电脑'));
    expect(text, contains('配对未通过'));
    expect(text, contains('便携机 第三方字段'));
  });
}
