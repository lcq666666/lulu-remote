import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PrivacyMode { off, black, image }

class PrivacySettings {
  const PrivacySettings(this.mode, {this.imagePath});

  final PrivacyMode mode;
  final String? imagePath;

  static const _modeKey = 'lulu_privacy_mode';
  static const _imageKey = 'lulu_privacy_image';

  static Future<PrivacySettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_modeKey);
    return PrivacySettings(
      PrivacyMode.values.firstWhere((value) => value.name == mode,
          orElse: () => PrivacyMode.off),
      imagePath: prefs.getString(_imageKey),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final path = imagePath;
    final imageSaved = path == null
        ? await prefs.remove(_imageKey)
        : await prefs.setString(_imageKey, path);
    if (!imageSaved || !await prefs.setString(_modeKey, mode.name)) {
      throw StateError('无法保存隐私屏设置。');
    }
  }
}

typedef PrivacyImage = ({String path, int width, int height});
typedef PrivacyPreview = ({bool imageFallback, bool hotkeyAvailable});

/// Keeps the preview and the tray-driven curtain in sync with the runner.
class PrivacyScreenService {
  PrivacyScreenService({
    MethodChannel channel = const MethodChannel('lulu/host_tray'),
  }) : _channel = channel;

  static final instance = PrivacyScreenService();
  final MethodChannel _channel;
  final _streaming = ValueNotifier<bool?>(null);
  final _previewing = ValueNotifier<bool>(false);
  final _liveImageFallback = ValueNotifier<bool>(false);
  bool _polling = false;
  bool _sessionActive = false;
  bool _live = false;
  int _generation = 0;

  ValueListenable<bool?> get streaming => _streaming;
  ValueListenable<bool> get previewing => _previewing;
  ValueListenable<bool> get liveImageFallback => _liveImageFallback;

  Future<void> stop() async {
    _generation++;
    _sessionActive = false;
    _streaming.value = null;
    await _syncCurtain(null, _generation);
  }

  Future<void> _syncCurtain(bool? active, int generation) async {
    try {
      if (active != true) {
        if (active == false) _sessionActive = false;
        if (_live || _previewing.value && active == null) {
          dismissed();
          await _channel.invokeMethod<void>('hidePrivacyScreen');
        }
        return;
      }
      if (_live) {
        await _channel.invokeMethod<void>('renewPrivacyScreen');
        return;
      }
      if (_sessionActive) return;
      _sessionActive = true;
      if (_previewing.value) await closePreview();
      final settings = await PrivacySettings.load();
      if (generation != _generation || settings.mode == PrivacyMode.off) return;
      // Mark it before calling into the runner so a stop can always hide it.
      _live = true;
      final result = await _channel.invokeMapMethod<String, bool>(
        'showPrivacyScreen',
        {'mode': settings.mode.name, 'image': settings.imagePath, 'live': true},
      );
      if (_live && generation == _generation) {
        _liveImageFallback.value = result?['imageFallback'] ?? false;
      }
    } on Exception {
      // The native curtain expires if renewal is unavailable. Keep the
      // current session latched so a hotkey or failure cannot reopen it.
      if (generation == _generation && _live) dismissed();
    } on StateError {
      if (generation == _generation && _live) dismissed();
    }
  }

  Future<void> poll({Future<void> Function(bool?)? onSample}) async {
    if (_polling) return;
    _polling = true;
    final generation = _generation;
    try {
      bool? active;
      try {
        active = await _channel.invokeMethod<bool>('sunshineStreaming');
      } on PlatformException {
        // Leave an unsuccessful sample unknown, not idle.
      } on MissingPluginException {
        // E.g. a launcher binary predating this channel method.
      }
      if (generation != _generation) return;
      _streaming.value = active;
      await _syncCurtain(active, generation);
      if (generation != _generation) return;
      if (onSample != null) await onSample(active);
    } finally {
      _polling = false;
    }
  }

  Future<PrivacyImage?> pickImage() async {
    final selected =
        await _channel.invokeMapMethod<String, Object?>('pickPrivacyImage');
    if (selected == null) return null;
    return (
      path: selected['path']! as String,
      width: selected['width']! as int,
      height: selected['height']! as int,
    );
  }

  Future<PrivacyPreview> preview(PrivacySettings settings) async {
    if (settings.mode == PrivacyMode.off) {
      throw StateError('请先选择黑屏或自定义图片。');
    }
    // Query again rather than relying on a sample from the previous tick.
    if (await _channel.invokeMethod<bool>('sunshineStreaming') != false) {
      throw StateError('串流正在进行或状态未知，暂不能预览。');
    }
    final result =
        await _channel.invokeMapMethod<String, bool>('showPrivacyScreen', {
      'mode': settings.mode.name,
      'image': settings.imagePath,
    });
    _previewing.value = true;
    return (
      imageFallback: result?['imageFallback'] ?? false,
      hotkeyAvailable: result?['hotkeyAvailable'] ?? false,
    );
  }

  Future<void> closePreview() async {
    if (!_previewing.value) return;
    await _channel.invokeMethod<void>('hidePrivacyScreen');
    previewClosed();
  }

  void previewClosed() => _previewing.value = false;

  void dismissed() {
    previewClosed();
    _live = false;
    _liveImageFallback.value = false;
  }
}
