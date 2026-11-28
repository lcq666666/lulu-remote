import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/stream_screen_selection.dart';

void main() {
  test('startup only retries on the Moonlight window without taking focus',
      () async {
    final calls = <(int, bool)>[];
    final selection =
        StreamScreenSelection(send: (screen, {required focus}) async {
      calls.add((screen, focus));
      return calls.length == 2;
    });
    expect(await selection.select(2, initial: true, retryDelay: Duration.zero),
        StreamScreenResult.sent);
    expect(calls, [(2, false), (2, false)]);
  });

  test('manual selection cancels startup retries and ignores a stale result',
      () async {
    final waiting = Completer<bool>();
    final calls = <(int, bool)>[];
    final selection = StreamScreenSelection(send: (screen, {required focus}) {
      calls.add((screen, focus));
      return focus ? Future.value(true) : waiting.future;
    });
    final initial =
        selection.select(2, initial: true, retryDelay: Duration.zero);
    expect(await selection.select(1, initial: false), StreamScreenResult.sent);
    waiting.complete(false);
    expect(await initial, StreamScreenResult.superseded);
    expect(calls, [(2, false), (1, true)]);
  });

  test('closing a stream stops pending attempts and rejects new requests',
      () async {
    final waiting = Completer<bool>();
    var calls = 0;
    final selection = StreamScreenSelection(send: (_, {required focus}) {
      calls++;
      return waiting.future;
    });
    final pending =
        selection.select(2, initial: true, retryDelay: Duration.zero);
    selection.close();
    waiting.complete(false);
    expect(await pending, StreamScreenResult.superseded);
    expect(await selection.select(1, initial: false),
        StreamScreenResult.superseded);
    expect(calls, 1);
  });

  test('a blocked manual shortcut is not repeated behind the user', () async {
    var calls = 0;
    final selection = StreamScreenSelection(send: (_, {required focus}) async {
      expect(focus, isTrue);
      calls++;
      return false;
    });
    expect(await selection.select(2, initial: false),
        StreamScreenResult.unavailable);
    expect(calls, 1);
  });

  test('an unavailable Windows handler stops startup polling', () async {
    var calls = 0;
    final selection = StreamScreenSelection(send: (_, {required focus}) async {
      calls++;
      throw MissingPluginException();
    });
    expect(await selection.select(2, initial: true, retryDelay: Duration.zero),
        StreamScreenResult.unavailable);
    expect(calls, 1);
  });
}
