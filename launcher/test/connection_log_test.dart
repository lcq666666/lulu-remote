import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/connection_log.dart';
import 'package:lulu_remote/services/sunshine_stream_log.dart';
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

  test('formats a failed stream using Sunshine evidence', () async {
    final started = DateTime.utc(2026, 11, 28, 1, 10);
    var clock = started;
    final observedEnd = started.add(const Duration(seconds: 12));
    final log = ConnectionLog(
      now: () => clock,
      streamEvidence: (sampledStart, sampledEnd) async =>
          SunshineStreamEvidence(started, observedEnd,
              failure: SunshineStreamFailure.networkTimeout),
    );
    await log.sessionSample(true);
    clock = started.add(const Duration(seconds: 13));
    await log.sessionSample(false);
    final row = (await log.read()).single;
    expect(row.end, observedEnd);
    expect(row.outcome, ConnectionOutcome.failed);
    expect(row.issue, ConnectionIssue.streamNetworkTimeout);
    expect(row.client, isEmpty);
    expect(
        ConnectionLog.exportText([row]), contains('串流失败 · Sunshine 与控制端通信超时'));
  });

  test('keeps the verified peer name and omits its address', () async {
    final started = DateTime.utc(2026, 11, 28, 1, 10);
    final ended = started.add(const Duration(seconds: 10));
    var clock = started;
    final peer = InternetAddress('100.90.8.4');
    final log = ConnectionLog(
      now: () => clock,
      streamEvidence: (_, __) async => SunshineStreamEvidence(started, ended,
          failure: SunshineStreamFailure.networkTimeout, peerAddress: peer),
      peerName: (address) async {
        expect(address, peer);
        return 'lab-pc';
      },
    );
    await log.sessionSample(true);
    clock = ended;
    await log.sessionSample(false);
    final row = (await ConnectionLog().read()).single;
    expect(row.client, 'lab-pc');
    expect(row.toJson().values, isNot(contains(peer.address)));
    expect(ConnectionLog.exportText([row]), isNot(contains(peer.address)));
  });

  test('captures known pairing outcomes and safely exports UTF-8 text',
      () async {
    final log = ConnectionLog();
    log.pairingSeen('one', '实验室电脑');
    await log.pairingCompleted('one');
    log.pairingSeen('two', '便携机\n第三方字段');
    await log.pairingFailed('two', ConnectionIssue.pairingApproval);
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
    expect(text, contains('配对未通过 · 未收到 Sunshine 的配对确认'));
    expect(text, contains('便携机 第三方字段'));
  });

  test('keeps a pending approval until its result arrives', () async {
    final log = ConnectionLog();
    const request = (id: 'one', name: '实验室电脑', address: '100.64.12.1');
    await log.pairingSample([request]);
    log.pairingApprovalStarted(request.id);
    await log.pairingSample([]);
    expect(await log.read(), isEmpty);
    await log.pairingCompleted(request.id);
    expect((await ConnectionLog().read()).single.outcome,
        ConnectionOutcome.completed);
  });

  test('finalizes failed approval after the request disappears', () async {
    final log = ConnectionLog();
    const request = (id: 'one', name: '实验室电脑', address: '100.64.12.1');
    await log.pairingSample([request]);
    log.pairingApprovalStarted(request.id);
    await log.pairingSample([]);
    await log.pairingFailed(request.id, ConnectionIssue.pairingLookup);
    final row = (await ConnectionLog().read()).single;
    expect(row.issue, ConnectionIssue.pairingLookup);
    expect(row.outcome, ConnectionOutcome.failed);
    expect(row.toJson().values, isNot(contains(request.address)));
  });

  test('ignores an old polling result after approval succeeds', () async {
    final log = ConnectionLog();
    const request = (id: 'one', name: '实验室电脑', address: '100.64.12.1');
    await log.pairingSample([request]);
    log.pairingApprovalStarted(request.id);
    await log.pairingCompleted(request.id);
    await log.pairingSample([request]);
    await log.pairingSample([]);
    expect((await log.read()).single.outcome, ConnectionOutcome.completed);
  });

  test('keeps a confirmed expired request from reappearing', () async {
    final log = ConnectionLog();
    const request = (id: 'one', name: '实验室电脑', address: '100.64.12.1');
    await log.pairingSample([request]);
    log.pairingApprovalStarted(request.id);
    await log.pairingFailed(request.id, ConnectionIssue.pairingEnded);
    await log.pairingSample([request]);
    await log.pairingSample([]);
    expect((await log.read()).single.issue, ConnectionIssue.pairingEnded);
  });

  test('reads a preexisting entry without an issue', () {
    final row = ConnectionEntry.fromJson({
      'kind': 'pairing',
      'start': '2026-11-28T00:00:00Z',
      'end': '2026-11-28T00:00:02Z',
      'client': '旧设备',
      'result': 'failed',
    });
    expect(row.issue, isNull);
    expect(row.duration.inSeconds, 2);
    expect(row.outcomeLabel, '配对未通过');
  });
}
