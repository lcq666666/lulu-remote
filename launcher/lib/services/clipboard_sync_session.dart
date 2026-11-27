import 'dart:async';
import 'dart:convert';

import 'host_tools_service.dart';

class ClipboardSyncSession {
  ClipboardSyncSession({
    required this.client,
    required this.readLocal,
    required this.writeLocal,
    required this.onError,
  });

  final HostToolsClient client;
  final Future<String> Function() readLocal;
  final Future<void> Function(String) writeLocal;
  final void Function(Object) onError;
  List<int>? _remoteDigest;
  String? _lastLocal;
  Timer? _timer;
  bool _stopped = false;
  bool _polling = false;

  Future<void> start({Duration interval = const Duration(seconds: 2)}) async {
    final initialLocal = await readLocal();
    if (_stopped) return;
    _lastLocal = initialLocal;
    final initialRemote = await client.watchClipboard(null);
    if (_stopped) return;
    _remoteDigest = initialRemote.digest;
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  Future<void> poll() async {
    final digest = _remoteDigest;
    if (_stopped || _polling || digest == null) return;
    _polling = true;
    try {
      final local = await readLocal();
      if (_stopped) return;
      if (local != _lastLocal) {
        _lastLocal = local;
        if (local.isNotEmpty &&
            local.length <= clipboardMaxBytes &&
            utf8.encode(local).length <= clipboardMaxBytes) {
          final digest = await client.pushClipboard(local);
          if (!_stopped) _remoteDigest = digest;
          return;
        }
      }
      final remote = await client.watchClipboard(digest);
      if (_stopped) return;
      final text = remote.text;
      if (text != null) {
        // A local copy during this request belongs to the next tick.
        final current = await readLocal();
        if (_stopped || current != local) return;
        await writeLocal(text);
        if (_stopped) return;
        _lastLocal = text;
      }
      _remoteDigest = remote.digest;
    } catch (error) {
      if (!_stopped) {
        stop();
        onError(error);
      }
    } finally {
      _polling = false;
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _lastLocal = null;
    _remoteDigest = null;
  }
}
