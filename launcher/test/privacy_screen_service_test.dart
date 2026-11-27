import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/privacy_screen_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/privacy_screen');
  late PrivacyScreenService service;
  late List<MethodCall> calls;
  bool? streaming;
  bool sampleThrows = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = PrivacyScreenService(channel: channel);
    calls = [];
    streaming = false;
    sampleThrows = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return switch (call.method) {
        'sunshineStreaming' => sampleThrows
            ? throw PlatformException(code: 'sample_failed')
            : streaming,
        'showPrivacyScreen' => {
            'imageFallback': call.arguments['mode'] == 'image',
            'hotkeyAvailable': false,
          },
        'hidePrivacyScreen' => null,
        'pickPrivacyImage' => {
            'path': 'cover.png',
            'width': 800,
            'height': 600
          },
        _ => throw MissingPluginException(),
      };
    });
  });

  tearDown(() =>
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('defaults to off with no image', () async {
    final settings = await PrivacySettings.load();
    expect(settings.mode, PrivacyMode.off);
    expect(settings.imagePath, isNull);
  });

  test('all settings round-trip and image path can be cleared', () async {
    for (final mode in PrivacyMode.values) {
      final path = mode == PrivacyMode.image ? r'C:\壁纸\测试.png' : null;
      await PrivacySettings(mode, imagePath: path).save();
      final settings = await PrivacySettings.load();
      expect(settings.mode, mode);
      expect(settings.imagePath, path);
    }
    await const PrivacySettings(PrivacyMode.black).save();
    expect((await PrivacySettings.load()).imagePath, isNull);
  });

  test('picker returns dimensions and preview reports image fallback',
      () async {
    expect(await service.pickImage(),
        (path: 'cover.png', width: 800, height: 600));
    expect(
        await service.preview(
            const PrivacySettings(PrivacyMode.image, imagePath: 'missing.png')),
        (imageFallback: true, hotkeyAvailable: false));
    expect(service.previewing.value, isTrue);
    expect(calls.last.arguments, {'mode': 'image', 'image': 'missing.png'});
  });

  test('off, active and unknown do not open a preview', () async {
    const black = PrivacySettings(PrivacyMode.black);
    await expectLater(service.preview(const PrivacySettings(PrivacyMode.off)),
        throwsStateError);
    for (final sample in [true, null]) {
      streaming = sample;
      await expectLater(service.preview(black), throwsStateError);
    }
    expect(calls.map((call) => call.method),
        ['sunshineStreaming', 'sunshineStreaming']);
    expect(service.previewing.value, isFalse);
  });

  test('confirmed stream start closes preview without showing live curtain',
      () async {
    await service.preview(const PrivacySettings(PrivacyMode.black));
    streaming = true;
    await service.poll();
    expect(service.streaming.value, isTrue);
    expect(service.previewing.value, isFalse);
    await service.poll();
    streaming = false;
    await service.poll();
    expect(service.streaming.value, isFalse);
    expect(calls.where((call) => call.method == 'showPrivacyScreen'),
        hasLength(1));
    expect(calls.where((call) => call.method == 'hidePrivacyScreen'),
        hasLength(1));
  });

  test('native preview dismissal and failed poll are not stream endings',
      () async {
    await service.preview(const PrivacySettings(PrivacyMode.black));
    service.previewClosed();
    await service.closePreview();
    streaming = true;
    await service.poll();
    sampleThrows = true;
    await service.poll();
    expect(service.streaming.value, isNull);
    expect(service.previewing.value, isFalse);
    expect(calls.where((call) => call.method == 'hidePrivacyScreen'), isEmpty);
  });
  test('unknown stream state closes an existing preview', () async {
    await service.preview(const PrivacySettings(PrivacyMode.black));
    sampleThrows = true;
    await service.poll();
    expect(service.streaming.value, isNull);
    expect(service.previewing.value, isFalse);
    expect(calls.last.method, 'hidePrivacyScreen');
  });
}
