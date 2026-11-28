import 'package:flutter/services.dart';

typedef SendStreamScreen = Future<bool> Function(int screen,
    {required bool focus});

enum StreamScreenResult { sent, unavailable, superseded }

/// Owns pending display requests for one Moonlight stream. An explicit choice
/// wins over startup retries, even if the previous platform call is in flight.
/// Windows only reports whether it sent the shortcut, not whether Sunshine
/// changed the remote display.
class StreamScreenSelection {
  StreamScreenSelection({required SendStreamScreen send}) : _send = send;

  final SendStreamScreen _send;
  int _request = 0;
  bool _closed = false;

  Future<StreamScreenResult> select(int screen,
      {required bool initial,
      int attempts = 24,
      Duration retryDelay = const Duration(milliseconds: 500)}) async {
    if (_closed) return StreamScreenResult.superseded;
    final request = ++_request;
    for (var attempt = 0; attempt < (initial ? attempts : 1); attempt++) {
      if (request != _request) return StreamScreenResult.superseded;
      try {
        final sent = await _send(screen, focus: !initial);
        if (request != _request) return StreamScreenResult.superseded;
        if (sent) return StreamScreenResult.sent;
      } on PlatformException {
        break;
      } on MissingPluginException {
        break;
      }
      if (initial && attempt + 1 < attempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    return request == _request
        ? StreamScreenResult.unavailable
        : StreamScreenResult.superseded;
  }

  void close() {
    _closed = true;
    _request++;
  }
}
