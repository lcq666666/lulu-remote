import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'sunshine_stream_log.dart';

enum ConnectionKind { pairing, streaming }

enum ConnectionOutcome { completed, expired, failed, interrupted }

enum ConnectionIssue {
  pairingLookup,
  pairingEnded,
  pairingApproval,
  streamLaunch,
  streamInitialTimeout,
  streamNetworkTimeout;

  String get label => switch (this) {
        pairingLookup => '无法核对 Sunshine 配对请求',
        pairingEnded => '配对请求已结束',
        pairingApproval => '未收到 Sunshine 的配对确认',
        streamLaunch => 'Sunshine 启动串流失败',
        streamInitialTimeout => 'Sunshine 等待控制端连接超时',
        streamNetworkTimeout => 'Sunshine 与控制端通信超时',
      };

  static ConnectionIssue? read(Object? name) =>
      values.where((value) => value.name == name).firstOrNull;
}

String cleanConnectionName(String name) {
  final text = name
      .replaceFirst(RegExp(r' · LULU-[a-f0-9]{32}$'), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
      .trim();
  return String.fromCharCodes(text.runes.take(80));
}

class ConnectionEntry {
  const ConnectionEntry(
      this.kind, this.start, this.end, this.client, this.outcome,
      {this.issue});

  factory ConnectionEntry.fromJson(Map<String, dynamic> json) =>
      ConnectionEntry(
        ConnectionKind.values.byName(json['kind'] as String),
        DateTime.parse(json['start'] as String),
        DateTime.parse(json['end'] as String),
        cleanConnectionName(json['client'] as String),
        ConnectionOutcome.values.byName(json['result'] as String),
        issue: ConnectionIssue.read(json['issue']),
      );

  final ConnectionKind kind;
  final DateTime start;
  final DateTime end;
  final String client;
  final ConnectionOutcome outcome;
  final ConnectionIssue? issue;

  Duration get duration =>
      end.isBefore(start) ? Duration.zero : end.difference(start);

  Map<String, String> toJson() => {
        'kind': kind.name,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'client': cleanConnectionName(client),
        'result': outcome.name,
        if (issue case final issue?) 'issue': issue.name,
      };

  String get kindLabel => switch (kind) {
        ConnectionKind.pairing => '配对',
        ConnectionKind.streaming => '串流',
      };
  String get outcomeLabel => switch (outcome) {
        ConnectionOutcome.completed => '完成',
        ConnectionOutcome.expired => '请求结束，结果未知',
        ConnectionOutcome.failed =>
          kind == ConnectionKind.pairing ? '配对未通过' : '串流失败',
        ConnectionOutcome.interrupted => '记录服务停止',
      };
  String get clientLabel => client.isEmpty ? '未识别控制端' : client;
}

class _PairingAttempt {
  _PairingAttempt(this.starts, this.name);

  final DateTime starts;
  final String name;
  bool present = true;
  bool approving = false;
  ConnectionIssue? issue;
}

class ConnectionLog {
  ConnectionLog({
    DateTime Function()? now,
    Future<SunshineStreamEvidence?> Function(DateTime, DateTime)?
        streamEvidence,
  })  : _now = now ?? DateTime.now,
        _streamEvidence = streamEvidence;

  static final instance = ConnectionLog(streamEvidence: SunshineStreamLog.read);
  static const _logKey = 'qg_connection_log_v1';
  final DateTime Function() _now;
  final Future<SunshineStreamEvidence?> Function(DateTime, DateTime)?
      _streamEvidence;
  Future<void> _writes = Future<void>.value();
  DateTime? _streamStart;
  final _pairing = <String, _PairingAttempt>{};
  final _finishedRequests = <String>{};

  Future<List<ConnectionEntry>> read() async {
    await _writes;
    return _decode(await SharedPreferences.getInstance());
  }

  List<ConnectionEntry> _decode(SharedPreferences prefs) {
    final result = <ConnectionEntry>[];
    for (final row in prefs.getStringList(_logKey) ?? <String>[]) {
      try {
        result.add(
            ConnectionEntry.fromJson(jsonDecode(row) as Map<String, dynamic>));
      } on Object {
        // Skip any corrupted entry independently of the rest of the log.
      }
    }
    return result;
  }

  Future<void> _append(ConnectionEntry entry) => _queueEntry(() async => entry);

  Future<void> _queueEntry(Future<ConnectionEntry> Function() load) async {
    final write = _writes.then((_) async {
      final entry = await load();
      final prefs = await SharedPreferences.getInstance();
      final rows = [entry, ..._decode(prefs)];
      rows.sort((left, right) => right.end.compareTo(left.end));
      if (!await prefs.setStringList(_logKey,
          rows.take(300).map((row) => jsonEncode(row.toJson())).toList())) {
        await prefs.reload();
      }
    });
    _writes = write.catchError((Object _) {});
    await _writes;
  }

  Future<void> sessionSample(bool? active) async {
    if (active == true) {
      _streamStart ??= _now();
    } else if (_streamStart case final start? when active == false) {
      _streamStart = null;
      final end = _now();
      await _queueEntry(() async {
        SunshineStreamEvidence? evidence;
        try {
          evidence = await _streamEvidence?.call(start, end);
        } on Exception {
          // Keep the sampled connection when the Sunshine log is unreadable.
        }
        final issue = switch (evidence?.failure) {
          SunshineStreamFailure.launch => ConnectionIssue.streamLaunch,
          SunshineStreamFailure.initialTimeout =>
            ConnectionIssue.streamInitialTimeout,
          SunshineStreamFailure.networkTimeout =>
            ConnectionIssue.streamNetworkTimeout,
          null => null,
        };
        return ConnectionEntry(
          ConnectionKind.streaming,
          evidence?.start ?? start,
          evidence?.end ?? end,
          '',
          issue == null
              ? ConnectionOutcome.completed
              : ConnectionOutcome.failed,
          issue: issue,
        );
      });
    }
  }

  void pairingSeen(String id, String client) {
    if (_finishedRequests.contains(id)) return;
    _pairing.putIfAbsent(
        id, () => _PairingAttempt(_now(), cleanConnectionName(client)));
  }

  void pairingApprovalStarted(String id) {
    _pairing[id]?.approving = true;
  }

  Future<void> pairingFailed(String id, ConnectionIssue issue) async {
    final attempt = _pairing[id];
    if (attempt == null) return;
    attempt.approving = false;
    attempt.issue = issue;
    if (!attempt.present || issue == ConnectionIssue.pairingEnded) {
      await _finishPairing(id);
    }
  }

  Future<void> _finishPairing(String id, {bool completed = false}) async {
    final attempt = _pairing.remove(id);
    if (attempt == null) return;
    if (attempt.present) _finishedRequests.add(id);
    final issue = completed ? null : attempt.issue;
    final outcome = completed
        ? ConnectionOutcome.completed
        : issue == null
            ? ConnectionOutcome.expired
            : ConnectionOutcome.failed;
    await _append(ConnectionEntry(
        ConnectionKind.pairing, attempt.starts, _now(), attempt.name, outcome,
        issue: issue));
  }

  Future<void> pairingCompleted(String id) =>
      _finishPairing(id, completed: true);

  Future<void> pairingSample(
      Iterable<({String id, String name, String address})> requests) async {
    final active = requests.map((request) => request.id).toSet();
    _finishedRequests.retainAll(active);
    for (final request in requests) {
      pairingSeen(request.id, request.name);
    }
    final expired = <String>[];
    for (final entry in _pairing.entries) {
      entry.value.present = active.contains(entry.key);
      if (!entry.value.present && !entry.value.approving) {
        expired.add(entry.key);
      }
    }
    await Future.wait(expired.map((id) => _finishPairing(id)));
  }

  Future<void> stop() async {
    final start = _streamStart;
    _streamStart = null;
    final attempts = _pairing.values.toList();
    _pairing.clear();
    _finishedRequests.clear();
    final now = _now();
    if (start != null) {
      await _append(ConnectionEntry(ConnectionKind.streaming, start, now, '',
          ConnectionOutcome.interrupted));
    }
    for (final attempt in attempts) {
      await _append(ConnectionEntry(ConnectionKind.pairing, attempt.starts, now,
          attempt.name, ConnectionOutcome.interrupted));
    }
  }

  static String exportText(Iterable<ConnectionEntry> entries) {
    final text = StringBuffer('强哥远程连接记录\n');
    for (final row in entries) {
      final detail = row.issue == null ? '' : ' · ${row.issue!.label}';
      text.writeln('${connectionTime(row.start)}  ${connectionTime(row.end)}  '
          '${row.kindLabel}  ${row.clientLabel}  ${row.duration.inSeconds} 秒  ${row.outcomeLabel}$detail');
    }
    return text.toString();
  }
}

String connectionDay(DateTime instant) {
  final date = instant.toLocal();
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String connectionTime(DateTime instant) {
  final date = instant.toLocal();
  String pair(int value) => value.toString().padLeft(2, '0');
  return '${connectionDay(date)} ${pair(date.hour)}:${pair(date.minute)}:${pair(date.second)}';
}
