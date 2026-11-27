import 'dart:convert';
import 'dart:io';

class SunshineStreamEvidence {
  const SunshineStreamEvidence(this.start, this.end, {this.failure});

  final DateTime start;
  final DateTime end;
  final SunshineStreamFailure? failure;
}

enum SunshineStreamFailure { launch, initialTimeout, networkTimeout }

/// Reads the default Windows installation log after a polled stream ends.
/// Only fixed Sunshine events leave this parser. No log lines or endpoints
/// are retained or exported.
class SunshineStreamLog {
  static const _maxBytes = 64 * 1024;
  static final _event = RegExp(
      r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]: (Info|Error): (.*)$');
  static final _sessionCount =
      RegExp(r'^New streaming session started \[active sessions: (\d+)\]$');
  static final _timeout = RegExp(r'^([a-fA-F0-9:.]+): Ping Timeout$');

  static Future<SunshineStreamEvidence?> read(
      DateTime sampledStart, DateTime sampledEnd) async {
    if (!Platform.isWindows) return null;
    final paths = {
      Platform.environment['ProgramW6432'],
      Platform.environment['ProgramFiles'],
    }.whereType<String>();
    for (final path in paths) {
      final current = '$path\\Sunshine\\config\\sunshine.log';
      final evidence = parse(
        await _tail(current),
        sampledStart,
        sampledEnd,
      );
      if (evidence != null) return evidence;
    }
    return null;
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
      if (level == 'Info' && message == 'CLIENT CONNECTED') {
        if (connected != null || result != null) return null;
        connected = time;
        continue;
      }
      if (time.isBefore(sampledStart)) continue;
      final failure = _failure(level, message);
      if (level == 'Info' && message == 'CLIENT DISCONNECTED') {
        // Sunshine may write a disconnect notification after a timeout.
        if (result?.failure != null) continue;
        if (connected == null || result != null || time.isBefore(connected)) {
          return null;
        }
        result = SunshineStreamEvidence(connected, time);
      } else if (failure != null) {
        if (result != null || (connected != null && time.isBefore(connected))) {
          return null;
        }
        result =
            SunshineStreamEvidence(connected ?? start, time, failure: failure);
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
    final match = level == 'Info' ? _timeout.firstMatch(message) : null;
    final address = match?.group(1);
    return address != null && InternetAddress.tryParse(address) != null
        ? SunshineStreamFailure.networkTimeout
        : null;
  }
}
