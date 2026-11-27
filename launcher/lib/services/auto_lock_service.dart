import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Watches the same host-side samples as the privacy screen. A failed sample
/// is unknown, not a disconnect; only a confirmed idle sample ends a session.
class AutoLockService {
  AutoLockService({
    MethodChannel channel = const MethodChannel('lulu/host_tray'),
  }) : _channel = channel;

  static const _preferenceKey = 'lulu_auto_lock';
  final MethodChannel _channel;
  bool _hadActiveSession = false;
  int _generation = 0;

  void reset() {
    _generation++;
    _hadActiveSession = false;
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_preferenceKey) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    // SharedPreferences changes its in-memory value before disk I/O finishes.
    // Restore the saved value if a write fails so the UI and tray agree.
    var saved = false;
    try {
      saved = await prefs.setBool(_preferenceKey, enabled);
    } finally {
      if (!saved) await prefs.reload();
    }
    if (!saved) throw StateError('无法保存自动锁屏设置。');
  }

  Future<void> onSessionSample(bool? active) async {
    if (active == null) return;
    if (active) {
      _hadActiveSession = true;
      return;
    }
    if (!_hadActiveSession) return;
    // Consume the edge before awaiting. Do not retry later on an idle tick,
    // even if the OS rejected the request or the setting was off at the time.
    _hadActiveSession = false;
    try {
      final generation = _generation;
      if (await isEnabled() && generation == _generation) {
        await _channel.invokeMethod<void>('lockAfterStream');
      }
    } on Exception {
      // Automatic locking from the tray must not interrupt the app or prompt.
    } on StateError {
      // A local settings failure is not sufficient reason to lock.
    }
  }
}
