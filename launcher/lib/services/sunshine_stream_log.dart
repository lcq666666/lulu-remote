import 'dart:convert';
import 'dart:io';

class SunshineStreamEvidence {
  const SunshineStreamEvidence(this.start, this.end,
      {this.failure, this.peerAddress});

  final DateTime start;
  final DateTime end;
  final SunshineStreamFailure? failure;
  final InternetAddress? peerAddress;
}

enum SunshineStreamFailure { launch, initialTimeout, networkTimeout }

/// Reads the default Windows installation log after a polled stream ends.
/// A confirmed peer address is available for an immediate local lookup.
/// Only the resulting peer name is retained in the connection history.
class SunshineStreamLog {
  static const _maxBytes = 64 * 1024;
  static final _event = RegExp(
      r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]: (Debug|Info|Error): (.*)$');
  static final _sessionCount =
      RegExp(r'^New streaming session started \[active sessions: (\d+)\]$');
  static final _timeout = RegExp(r'^([a-fA-F0-9:.]+): Ping Timeout$');
  static final _controlPeer =
      RegExp(r'^Control peer address \[([a-fA-F0-9:.]+):(\d{1,5})\]$');

  static Future<SunshineStreamEvidence?> read(
      DateTime sampledStart, DateTime sampledEnd) async {
    for (final path in _windowsLogs) {
      final evidence = parse(
        await _tail(path),
        sampledStart,
        sampledEnd,
      );
      if (evidence != null) return evidence;
    }
    return null;
  }

  static Iterable<String> get _windowsLogs sync* {
    if (!Platform.isWindows) return;
    for (final root in {
      Platform.environment['ProgramW6432'],
      Platform.environment['ProgramFiles'],
    }.whereType<String>()) {
      yield '$root\\Sunshine\\config\\sunshine.log';
    }
  }

  static Future<List<SunshineStreamEvidence>> readIdleSessions(
      DateTime idleSince, DateTime after, DateTime through) async {
    for (final path in _windowsLogs) {
      final text = await _tail(path);
      if (text.isNotEmpty) {
        return parseIdleSessions(text, idleSince, after, through);
      }
    }
    return const [];
  }

  /// Recover sessions the transport poll entirely missed. A complete, single
  /// attempt must begin in the confirmed-idle span and end after its cursor.
  /// Nothing here changes the live privacy or lock screen state.
  static List<SunshineStreamEvidence> parseIdleSessions(
      String text, DateTime idleSince, DateTime after, DateTime through) {
    final sessions = <SunshineStreamEvidence>[];
    final attempt = <String>[];
    DateTime? launched;
    var overlapped = false;
    DateTime? latest;

    void finishAttempt() {
      final start = launched;
      if (start == null || overlapped) return;
      final entry = parse(attempt.join('\n'), start, through);
      if (entry == null || !entry.end.isAfter(after)) return;
      if (entry.failure == SunshineStreamFailure.launch &&
          entry.end.difference(start) > const Duration(seconds: 3)) return;
      sessions.add(entry);
    }

    for (final line in const LineSplitter().convert(text)) {
      final event = _event.firstMatch(line);
      if (event == null) continue;
      final level = event[2];
      final message = event[3]!;
      final count = level == 'Info' ? _sessionCount.firstMatch(message) : null;
      final failure = _failure(level, message);
      if (count == null &&
          failure == null &&
          !(level == 'Info' &&
              (message == 'CLIENT CONNECTED' ||
                  message == 'CLIENT DISCONNECTED' ||
                  _timeout.hasMatch(message))) &&
          !(level == 'Debug' && message.startsWith('Control peer address ['))) {
        continue;
      }
      final time = DateTime.tryParse(event[1]!);
      if (time == null || time.isBefore(idleSince) || time.isAfter(through)) {
        continue;
      }
      // Do not match events across a clock rollback. Drop the ambiguous
      // attempt but retain already finished ones and let a new launch recover.
      if (latest != null && time.isBefore(latest)) {
        launched = null;
        attempt.clear();
        continue;
      }
      latest = time;
      if (count != null) {
        if (count[1] != '1') {
          overlapped = true;
          continue;
        }
        finishAttempt();
        launched = time;
        overlapped = false;
        attempt.clear();
      }
      if (launched == null || overlapped) continue;
      attempt.add(line);
      // A launch error ends the RTSP attempt before any stream can start.
      // Subsequent errors or slot announcements cannot belong to that attempt.
      if (failure == SunshineStreamFailure.launch) {
        finishAttempt();
        launched = null;
        attempt.clear();
      }
    }
    finishAttempt();
    return sessions;
  }

  static Future<String> _tail(String path) async {
    RandomAccessFile? file;
    try {
      file = await File(path).open();
      final length = await file.length();
      final start = length > _maxBytes ? length - _maxBytes : 0;
      await file.setPosition(start);
      final tail =
          utf8.decode(await file.read(_maxBytes), allowMalformed: true);
      if (start == 0) return tail;
      final firstNewline = tail.indexOf('\n');
      return firstNewline < 0 ? '' : tail.substring(firstNewline + 1);
    } on FileSystemException {
      return '';
    } finally {
      try {
        await file?.close();
      } on FileSystemException {
        // The installer can rotate or remove the log while it is open.
      }
    }
  }

  static SunshineStreamEvidence? parse(
      String text, DateTime sampledStart, DateTime sampledEnd) {
    // The host polls every two seconds. An immediately preceding session can
    // appear in this window too, so require exactly one launch and outcome.
    final earliest = sampledStart.subtract(const Duration(seconds: 3));
    if (sampledEnd.isBefore(sampledStart)) return null;
    DateTime? launched;
    DateTime? connected;
    InternetAddress? controlPeer;
    var peerEvents = 0;
    SunshineStreamEvidence? result;
    for (final line in const LineSplitter().convert(text)) {
      final event = _event.firstMatch(line);
      if (event == null) continue;
      final time = DateTime.tryParse(event[1]!);
      if (time == null || time.isBefore(earliest) || time.isAfter(sampledEnd)) {
        continue;
      }
      final level = event[2];
      final message = event[3]!;
      final count = level == 'Info' ? _sessionCount.firstMatch(message) : null;
      if (count != null) {
        if (launched != null || count[1] != '1') return null;
        launched = time;
        continue;
      }
      final start = launched;
      if (start == null || time.isBefore(start)) continue;
      // Stock Sunshine emits this Debug event after identifying the incoming
      // control connection and just before CLIENT CONNECTED. Use it only for
      // an unambiguous single session. This does not enable debug logging.
      if (level == 'Debug' &&
          connected == null &&
          result == null &&
          message.startsWith('Control peer address [')) {
        peerEvents++;
        final match = _controlPeer.firstMatch(message);
        final port = int.tryParse(match?.group(2) ?? '') ?? 0;
        if (peerEvents == 1 && match != null && port > 0 && port <= 65535) {
          controlPeer = InternetAddress.tryParse(match[1]!);
        } else {
          controlPeer = null;
        }
        continue;
      }
      if (level == 'Info' && message == 'CLIENT CONNECTED') {
        if (connected != null || result != null) return null;
        connected = time;
        continue;
      }
      if (time.isBefore(sampledStart)) continue;
      final peer = level == 'Info'
          ? InternetAddress.tryParse(
              _timeout.firstMatch(message)?.group(1) ?? '')
          : null;
      final failure = peer == null
          ? _failure(level, message)
          : SunshineStreamFailure.networkTimeout;
      if (level == 'Info' && message == 'CLIENT DISCONNECTED') {
        // Sunshine may write a disconnect notification after a timeout.
        if (result?.failure != null) continue;
        if (connected == null || result != null || time.isBefore(connected)) {
          return null;
        }
        result =
            SunshineStreamEvidence(connected, time, peerAddress: controlPeer);
      } else if (failure != null) {
        if (result != null ||
            (connected != null &&
                (time.isBefore(connected) ||
                    failure == SunshineStreamFailure.launch))) {
          return null;
        }
        result = SunshineStreamEvidence(connected ?? start, time,
            failure: failure, peerAddress: peer);
      }
    }
    return result;
  }

  static SunshineStreamFailure? _failure(String? level, String message) {
    if (level == 'Error') {
      return switch (message) {
        'Failed to start a streaming session' => SunshineStreamFailure.launch,
        'Initial Ping Timeout' => SunshineStreamFailure.initialTimeout,
        _ => null,
      };
    }
    return null;
  }
}
