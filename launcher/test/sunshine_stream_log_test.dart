import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/sunshine_stream_log.dart';

String _event(String at, String message, {String level = 'Info'}) =>
    '[2026-11-28 12:00:$at]: $level: $message';

void main() {
  final sampledStart = DateTime(2026, 11, 28, 12, 0, 4);
  final sampledEnd = DateTime(2026, 11, 28, 12, 0, 22);
  final launch =
      _event('02.250', 'New streaming session started [active sessions: 1]');
  final connect = _event('03.500', 'CLIENT CONNECTED');
  final disconnect = _event('20.000', 'CLIENT DISCONNECTED');

  SunshineStreamEvidence? parse(List<String> lines) =>
      SunshineStreamLog.parse(lines.join('\r\n'), sampledStart, sampledEnd);

  test('reads only fresh explicit launch failures in the idle window', () {
    final idle = DateTime(2026, 11, 28, 12, 0, 1);
    final lastRead = DateTime(2026, 11, 28, 12, 0, 4);
    String begun(String at, [int count = 1]) =>
        _event(at, 'New streaming session started [active sessions: $count]');
    String failed(String at) =>
        _event(at, 'Failed to start a streaming session', level: 'Error');
    final evidence = SunshineStreamLog.parseIdleSessions(
        [
          begun('02.250'), failed('03.000'), // Already read.
          begun('03.250'), failed('04.100'), // Crosses the last read boundary.
          failed('04.200'), // No new launch.
          begun('04.300', 2), failed('04.500'), // Overlapping session.
          begun('05.000'), _event('05.100', 'CLIENT CONNECTED'),
          failed('05.200'),
          begun('06.000'), failed('10.000'), // Too far apart to attribute.
          begun('11.000'), failed('11.050'),
          begun('22.100'), failed('22.150'), // Later than this poll.
        ].join('\n'),
        idle,
        lastRead,
        sampledEnd);
    expect(evidence.map((entry) => entry.end), [
      DateTime(2026, 11, 28, 12, 0, 4, 100),
      DateTime(2026, 11, 28, 12, 0, 11, 50),
    ]);
    expect(
        evidence.every((entry) =>
            entry.peerAddress == null &&
            entry.failure == SunshineStreamFailure.launch),
        isTrue);
  });

  test('recovers a complete short stream with verified timing and peer', () {
    final end = DateTime(2026, 11, 28, 12, 0, 5);
    final idle = DateTime(2026, 11, 28, 12, 0, 2);
    final log = [
      launch,
      _event('03.400', 'Control peer address [100.64.12.1:60421]',
          level: 'Debug'),
      connect,
      _event('03.750', 'CLIENT DISCONNECTED'),
    ].join('\n');
    final sessions = SunshineStreamLog.parseIdleSessions(log, idle, idle, end);
    final session = sessions.single;
    expect(session.start, DateTime(2026, 11, 28, 12, 0, 3, 500));
    expect(session.end, DateTime(2026, 11, 28, 12, 0, 3, 750));
    expect(session.failure, isNull);
    expect(session.peerAddress?.address, '100.64.12.1');
    expect(SunshineStreamLog.parseIdleSessions(log, idle, session.end, end),
        isEmpty);
  });

  test('idle log does not infer an end for partial or overlapping sessions',
      () {
    final idle = DateTime(2026, 11, 28, 12, 0, 2);
    for (final lines in [
      [launch, connect],
      [connect, disconnect],
      [launch, connect, _event('21.000', 'CLIENT CONNECTED'), disconnect],
      [
        launch,
        connect,
        _event('04.000', 'New streaming session started [active sessions: 2]'),
        disconnect,
      ],
    ]) {
      expect(
        SunshineStreamLog.parseIdleSessions(
            lines.join('\n'), idle, idle, sampledEnd),
        isEmpty,
        reason: lines.join(' | '),
      );
    }
  });

  test('idle log skips a clock reversal and resumes at the next launch', () {
    final idle = DateTime(2026, 11, 28, 12, 0, 2);
    final sessions = SunshineStreamLog.parseIdleSessions(
      [
        launch,
        connect,
        _event('03.100', 'CLIENT DISCONNECTED'),
        _event('05.000', 'New streaming session started [active sessions: 1]'),
        _event('06.000', 'CLIENT CONNECTED'),
        _event('06.950', 'Display probe message'), // From another log thread.
        _event('06.900', 'CLIENT DISCONNECTED'),
        _event('07.000', 'New streaming session started [active sessions: 1]'),
        _event('07.500', 'CLIENT CONNECTED'),
        _event('07.800', 'CLIENT DISCONNECTED'),
      ].join('\n'),
      idle,
      idle,
      sampledEnd,
    );
    expect(sessions.map((entry) => entry.end), [
      DateTime(2026, 11, 28, 12, 0, 6, 900),
      DateTime(2026, 11, 28, 12, 0, 7, 800),
    ]);
  });

  test('matches Sunshine activity and keeps precise local timestamps', () {
    final evidence = parse([launch, connect, disconnect])!;
    expect(evidence.start, DateTime(2026, 11, 28, 12, 0, 3, 500));
    expect(evidence.end, DateTime(2026, 11, 28, 12, 0, 20));
    expect(evidence.failure, isNull);
    expect(evidence.peerAddress, isNull);
  });

  test('uses an existing Debug address for an ordinary disconnect', () {
    for (final address in ['100.64.12.1', 'fd7a:115c:a1e0::1234']) {
      final evidence = parse([
        launch,
        _event('03.500', 'Control peer address [$address:60421]',
            level: 'Debug'),
        connect,
        disconnect,
      ])!;
      expect(evidence.peerAddress?.address, address);
      expect(evidence.failure, isNull);
    }
  });

  test('rejects ambiguous, malformed and out-of-sequence peer events', () {
    final peer = _event('03.200', 'Control peer address [100.64.12.1:60421]',
        level: 'Debug');
    for (final lines in [
      [peer, launch, connect, disconnect],
      [launch, connect, peer, disconnect],
      [launch, peer, peer, connect, disconnect],
      [
        launch,
        _event('03.200', 'Control peer address [100.64.12.1:65536]',
            level: 'Debug'),
        connect,
        disconnect,
      ],
      [
        launch,
        _event('03.200', 'Control peer address [100.64.12.1:60421]'),
        connect,
        disconnect,
      ],
    ]) {
      expect(parse(lines)!.peerAddress, isNull, reason: lines.join(' | '));
    }
  });

  test('recovers a Sunshine network timeout with a typed failure code', () {
    final evidence = parse([
      launch,
      connect,
      _event('19.750', '192.0.2.1: Ping Timeout'),
      disconnect,
    ])!;
    expect(evidence.failure, SunshineStreamFailure.networkTimeout);
    expect(evidence.peerAddress?.address, '192.0.2.1');
    expect(evidence.end, DateTime(2026, 11, 28, 12, 0, 19, 750));
  });

  test('recognizes the initial timeout when connection never completes', () {
    final evidence = parse([
      launch,
      _event('18.000', 'Initial Ping Timeout', level: 'Error'),
    ])!;
    expect(evidence.failure, SunshineStreamFailure.initialTimeout);
    expect(evidence.start, DateTime(2026, 11, 28, 12, 0, 2, 250));
  });

  test('falls back for unknown logs and overlapping sessions', () {
    expect(parse([launch, disconnect]), isNull);
    expect(parse([connect, disconnect]), isNull);
    expect(parse([launch, connect, _event('23.000', 'CLIENT DISCONNECTED')]),
        isNull);
    expect(
        parse([
          launch,
          connect,
          _event(
              '10.000', 'New streaming session started [active sessions: 2]'),
          disconnect,
        ]),
        isNull);
    expect(
        parse([
          launch,
          connect,
          _event('19.000', 'arbitrary name: Ping Timeout'),
        ]),
        isNull);
  });
}
