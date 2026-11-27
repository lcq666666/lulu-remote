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
