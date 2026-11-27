import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum ConnectionKind { pairing, streaming }

enum ConnectionOutcome { completed, expired, failed, interrupted }

String cleanConnectionName(String name) {
  final text = name
      .replaceFirst(RegExp(r' · LULU-[a-f0-9]{32}$'), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
      .trim();
  return String.fromCharCodes(text.runes.take(80));
}

class ConnectionEntry {
  const ConnectionEntry(
      this.kind, this.start, this.end, this.client, this.outcome);

  factory ConnectionEntry.fromJson(Map<String, dynamic> json) =>
      ConnectionEntry(
        ConnectionKind.values.byName(json['kind'] as String),
        DateTime.parse(json['start'] as String),
        DateTime.parse(json['end'] as String),
        cleanConnectionName(json['client'] as String),
        ConnectionOutcome.values.byName(json['result'] as String),
      );

  final ConnectionKind kind;
  final DateTime start;
  final DateTime end;
  final String client;
  final ConnectionOutcome outcome;

  Duration get duration =>
      end.isBefore(start) ? Duration.zero : end.difference(start);

  Map<String, String> toJson() => {
        'kind': kind.name,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'client': cleanConnectionName(client),
        'result': outcome.name,
      };

  String get kindLabel => switch (kind) {
        ConnectionKind.pairing => '配对',
        ConnectionKind.streaming => '串流',
      };
  String get outcomeLabel => switch (outcome) {
        ConnectionOutcome.completed => '完成',
        ConnectionOutcome.expired => '请求结束，结果未知',
        ConnectionOutcome.failed => '配对未通过',
        ConnectionOutcome.interrupted => '记录服务停止',
      };
  String get clientLabel => client.isEmpty ? '未识别控制端' : client;
}

class ConnectionLog {
  ConnectionLog({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final instance = ConnectionLog();
  static const _logKey = 'qg_connection_log_v1';
  final DateTime Function() _now;
  Future<void> _writes = Future<void>.value();
  DateTime? _streamStart;
  final _pairing = <String, ({DateTime starts, String name, bool failed})>{};

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

  Future<void> _append(ConnectionEntry entry) async {
    final write = _writes.then((_) async {
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
      await _append(ConnectionEntry(ConnectionKind.streaming, start, _now(), '',
          ConnectionOutcome.completed));
    }
  }

  void pairingSeen(String id, String client) {
    _pairing.putIfAbsent(
        id,
        () =>
            (starts: _now(), name: cleanConnectionName(client), failed: false));
  }

  void pairingFailed(String id) {
    if (_pairing[id] case final attempt?) {
      _pairing[id] = (starts: attempt.starts, name: attempt.name, failed: true);
    }
  }

  Future<void> pairingCompleted(String id) async {
    final attempt = _pairing.remove(id);
    if (attempt == null) return;
    await _append(ConnectionEntry(ConnectionKind.pairing, attempt.starts,
        _now(), attempt.name, ConnectionOutcome.completed));
  }

  Future<void> pairingSample(
      Iterable<({String id, String name, String address})> requests) async {
    final active = requests.map((request) => request.id).toSet();
    for (final request in requests) {
      pairingSeen(request.id, request.name);
    }
    final expired = _pairing.keys.where((id) => !active.contains(id)).toList();
    for (final id in expired) {
      final attempt = _pairing.remove(id)!;
      await _append(ConnectionEntry(
          ConnectionKind.pairing,
          attempt.starts,
          _now(),
          attempt.name,
          attempt.failed
              ? ConnectionOutcome.failed
              : ConnectionOutcome.expired));
    }
  }

  Future<void> stop() async {
    final start = _streamStart;
    _streamStart = null;
    final attempts = _pairing.values.toList();
    _pairing.clear();
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
      text.writeln('${connectionTime(row.start)}  ${connectionTime(row.end)}  '
          '${row.kindLabel}  ${row.clientLabel}  ${row.duration.inSeconds} 秒  ${row.outcomeLabel}');
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
