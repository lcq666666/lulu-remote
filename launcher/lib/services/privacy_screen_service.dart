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

/// Owns the state of the Windows privacy-screen preview. Live masking is not
/// enabled until capture exclusion and remote input work on the stock host.
class PrivacyScreenService {
  PrivacyScreenService({
    MethodChannel channel = const MethodChannel('lulu/host_tray'),
  }) : _channel = channel;

  static final instance = PrivacyScreenService();
  final MethodChannel _channel;
  final _streaming = ValueNotifier<bool?>(null);
  final _previewing = ValueNotifier<bool>(false);
  bool _polling = false;

  ValueListenable<bool?> get streaming => _streaming;
  ValueListenable<bool> get previewing => _previewing;

  Future<void> poll({Future<void> Function(bool?)? onSample}) async {
    if (_polling) return;
    _polling = true;
    try {
      bool? active;
      try {
        active = await _channel.invokeMethod<bool>('sunshineStreaming');
      } on PlatformException {
        // Leave an unsuccessful sample unknown, not idle.
      } on MissingPluginException {
        // E.g. a launcher binary predating this channel method.
      }
      _streaming.value = active;
      if (active != false && _previewing.value) {
        try {
          await closePreview();
        } on PlatformException {
          // The runner's timer is the fallback if closing fails.
        } on MissingPluginException {
          // No runner API available.
        }
      }
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
}
