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
  int _nextCurtainId = 0;
  int? _curtainId;
  Future<void> _curtainWork = Future.value();

  ValueListenable<bool?> get streaming => _streaming;
  ValueListenable<bool> get previewing => _previewing;
  ValueListenable<bool> get liveImageFallback => _liveImageFallback;

  // Run preview, polling and shutdown in the same order as their requests.
  Future<T> _queueCurtain<T>(Future<T> Function() action) {
    final result = _curtainWork.then((_) => action());
    _curtainWork =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> stop() {
    final generation = ++_generation;
    return _queueCurtain(() async {
      _sessionActive = false;
      _streaming.value = null;
      await _syncCurtain(null, generation);
    });
  }

  Future<Map<String, bool>?> _show(PrivacySettings settings,
      {required bool live}) async {
    final id = ++_nextCurtainId;
    _curtainId = id;
    _live = live;
    try {
      final result = await _channel.invokeMapMethod<String, bool>(
        'showPrivacyScreen',
        {
          'mode': settings.mode.name,
          'image': settings.imagePath,
          'live': live,
          'id': id,
        },
      );
      if (_curtainId == id) {
        _previewing.value = !live;
        _liveImageFallback.value = live && (result?['imageFallback'] ?? false);
      }
      return result;
    } catch (_) {
      dismissed(id);
      rethrow;
    }
  }

  Future<void> _hide() async {
    _clearCurtain();
    await _channel.invokeMethod<void>('hidePrivacyScreen');
  }

  Future<void> _syncCurtain(bool? active, int generation) async {
    try {
      if (active != true) {
        if (active == false) _sessionActive = false;
        if (_live || _previewing.value && active == null) await _hide();
        return;
      }
      if (_live) {
        await _channel.invokeMethod<void>('renewPrivacyScreen');
        return;
      }
      if (_sessionActive) return;
      _sessionActive = true;
      if (_previewing.value) await _hide();
      final settings = await PrivacySettings.load();
      if (generation != _generation || settings.mode == PrivacyMode.off) return;
      await _show(settings, live: true);
    } on Exception {
      // The native curtain expires if renewal is unavailable. Keep the
      // current session latched so a hotkey or failure cannot reopen it.
      if (generation == _generation && _live) _clearCurtain();
    } on StateError {
      if (generation == _generation && _live) _clearCurtain();
    }
  }

  Future<void> poll({Future<void> Function(bool?)? onSample}) async {
    if (_polling) return;
    _polling = true;
    final generation = _generation;
    try {
      final active = await _queueCurtain(() async {
        if (generation != _generation) return null;
        bool? sample;
        try {
          sample = await _channel.invokeMethod<bool>('sunshineStreaming');
        } on PlatformException {
          // Leave an unsuccessful sample unknown, not idle.
        } on MissingPluginException {
          // E.g. a launcher binary predating this channel method.
        }
        if (generation != _generation) return null;
        _streaming.value = sample;
        await _syncCurtain(sample, generation);
        return sample;
      });
      if (generation == _generation && onSample != null) await onSample(active);
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

  Future<PrivacyPreview> preview(PrivacySettings settings) {
    final generation = _generation;
    return _queueCurtain(() async {
      if (settings.mode == PrivacyMode.off) {
        throw StateError('请先选择黑屏或自定义图片。');
      }
      // Query again rather than relying on a sample from the previous tick.
      if (await _channel.invokeMethod<bool>('sunshineStreaming') != false ||
          generation != _generation) {
        throw StateError('串流正在进行或状态未知，暂不能预览。');
      }
      final result = await _show(settings, live: false);
      return (
        imageFallback: result?['imageFallback'] ?? false,
        hotkeyAvailable: result?['hotkeyAvailable'] ?? false,
      );
    });
  }

  Future<void> closePreview() => _queueCurtain(() async {
        if (_previewing.value) await _hide();
      });

  void dismissed(int id) {
    if (_curtainId == id) _clearCurtain();
  }

  void _clearCurtain() {
    _curtainId = null;
    _previewing.value = false;
    _live = false;
    _liveImageFallback.value = false;
  }
}
