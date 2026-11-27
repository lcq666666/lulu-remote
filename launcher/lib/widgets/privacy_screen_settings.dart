import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/privacy_screen_service.dart';
import 'lulu_ui.dart';

class PrivacyScreenSettings extends StatefulWidget {
  const PrivacyScreenSettings({super.key});

  @override
  State<PrivacyScreenSettings> createState() => _PrivacyScreenSettingsState();
}

class _PrivacyScreenSettingsState extends State<PrivacyScreenSettings> {
  final _service = PrivacyScreenService.instance;
  PrivacySettings? _settings;
  bool _busy = false;
  bool _fallback = false;
  bool _hotkeyUnavailable = false;
  bool _smallImage = false;

  @override
  void initState() {
    super.initState();
    _run(() async {
      final settings = await PrivacySettings.load();
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on StateError catch (error) {
      if (mounted) showLuluSnack(context, error.message);
    } on PlatformException catch (error) {
      if (!mounted) return;
      showLuluSnack(
          context,
          switch (error.code) {
            'privacy_image' => '图片打不开，请选择有效的 JPG 或 PNG。',
            'privacy_streaming' => '串流正在进行或状态未知，暂不能预览。',
            _ => '隐私屏操作未完成，请重试。',
          });
    } on Exception {
      if (mounted) showLuluSnack(context, '隐私屏操作未完成，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(PrivacySettings settings, {bool? smallImage}) async {
    await settings.save();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _fallback = false;
      if (smallImage != null) _smallImage = smallImage;
    });
  }

  Future<void> _pickImage() async {
    final image = await _service.pickImage();
    if (image == null) return;
    await _save(PrivacySettings(PrivacyMode.image, imagePath: image.path),
        smallImage: image.width < 1920 || image.height < 1080);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('隐私屏', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text('目前仅支持本机预览，串流时不会自动遮挡屏幕。'),
          if (settings != null) ...[
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: _service.previewing,
              builder: (context, previewing, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<PrivacyMode>(
                    value: settings.mode,
                    decoration: const InputDecoration(labelText: '预览模式'),
                    items: const [
                      DropdownMenuItem(
                          value: PrivacyMode.off, child: Text('关闭')),
                      DropdownMenuItem(
                          value: PrivacyMode.black, child: Text('黑屏')),
                      DropdownMenuItem(
                          value: PrivacyMode.image, child: Text('自定义图片')),
                    ],
                    onChanged: _busy || previewing
                        ? null
                        : (mode) {
                            if (mode != null) {
                              _run(() => _save(PrivacySettings(mode,
                                  imagePath: settings.imagePath)));
                            }
                          },
                  ),
                  if (settings.mode == PrivacyMode.image) ...[
                    const SizedBox(height: 8),
                    if (settings.imagePath case final path?)
                      SelectableText(path),
                    OutlinedButton.icon(
                      onPressed:
                          _busy || previewing ? null : () => _run(_pickImage),
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('选择 JPG / PNG'),
                    ),
                    if (_smallImage) const Text('建议用 1920×1080 以上的图片。'),
                    if (_fallback) const Text('图片打不开，已用黑屏代替。'),
                  ],
                  const SizedBox(height: 8),
                  ValueListenableBuilder<bool?>(
                    valueListenable: _service.streaming,
                    builder: (context, streaming, _) => Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilledButton.tonal(
                          onPressed: _busy ||
                                  previewing ||
                                  streaming != false ||
                                  settings.mode == PrivacyMode.off
                              ? null
                              : () => _run(() async {
                                    final preview =
                                        await _service.preview(settings);
                                    if (mounted) {
                                      setState(() {
                                        _fallback = preview.imageFallback;
                                        _hotkeyUnavailable =
                                            !preview.hotkeyAvailable;
                                      });
                                    }
                                  }),
                          child: const Text('立即预览'),
                        ),
                        OutlinedButton(
                          onPressed: _busy || !previewing
                              ? null
                              : () => _run(_service.closePreview),
                          child: const Text('关闭预览'),
                        ),
                      ],
                    ),
                  ),
                  Text(_hotkeyUnavailable
                      ? 'Ctrl+Alt+P 不可用，可点关闭按钮或等待 12 秒自动退出。'
                      : '预览 12 秒后自动关闭，也可按 Ctrl+Alt+P 退出。'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
