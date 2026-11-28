import 'dart:async';

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
  Future<void> Function(MethodCall)? beforeShowReply;

  int curtainId(MethodCall call) => call.arguments['id']! as int;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = PrivacyScreenService(channel: channel);
    calls = [];
    streaming = false;
    sampleThrows = false;
    beforeShowReply = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      if (call.method == 'showPrivacyScreen') await beforeShowReply?.call(call);
      return switch (call.method) {
        'sunshineStreaming' => sampleThrows
            ? throw PlatformException(code: 'sample_failed')
            : streaming,
        'showPrivacyScreen' => {
            'imageFallback': call.arguments['mode'] == 'image',
            'hotkeyAvailable': false,
          },
        'hidePrivacyScreen' || 'renewPrivacyScreen' => null,
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
    expect(calls.last.arguments,
        {'mode': 'image', 'image': 'missing.png', 'live': false, 'id': 1});
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

  test('tray shows curtain once, renews while streaming and hides at idle',
      () async {
    await const PrivacySettings(PrivacyMode.image, imagePath: 'missing.png')
        .save();
    streaming = true;
    await service.poll();
    expect(calls.last.arguments,
        {'mode': 'image', 'image': 'missing.png', 'live': true, 'id': 1});
    expect(service.liveImageFallback.value, isTrue);
    await const PrivacySettings(PrivacyMode.off).save();
    await service.poll();
    expect(calls.last.method, 'renewPrivacyScreen');
    streaming = false;
    await service.poll();
    expect(calls.last.method, 'hidePrivacyScreen');
    expect(service.liveImageFallback.value, isFalse);
    streaming = true;
    await service.poll();
    expect(calls.last.method, 'sunshineStreaming');
  });

  test('hotkey dismissal stays latched until the next confirmed stream',
      () async {
    await const PrivacySettings(PrivacyMode.black).save();
    streaming = true;
    await service.poll();
    service.dismissed(curtainId(calls.last));
    await service.poll();
    expect(calls.last.method, 'sunshineStreaming');
    streaming = false;
    await service.poll();
    streaming = true;
    await service.poll();
    expect(calls.last.method, 'showPrivacyScreen');
  });

  test('unknown sample closes live curtain without ending the session',
      () async {
    await const PrivacySettings(PrivacyMode.black).save();
    streaming = true;
    await service.poll();
    final samples = <bool?>[];
    sampleThrows = true;
    await service.poll(onSample: (sample) async => samples.add(sample));
    expect(calls.last.method, 'hidePrivacyScreen');
    expect(samples, [null]);
    sampleThrows = false;
    beforeShowReply = null;
    await service.poll();
    expect(calls.last.method, 'sunshineStreaming');
  });

  test('stopping the tray releases the live curtain', () async {
    await const PrivacySettings(PrivacyMode.black).save();
    streaming = true;
    await service.poll();
    await service.stop();
    expect(calls.last.method, 'hidePrivacyScreen');
    expect(service.streaming.value, isNull);
  });

  test('native preview dismissal and failed poll are not stream endings',
      () async {
    await service.preview(const PrivacySettings(PrivacyMode.black));
    service.dismissed(curtainId(calls.last));
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

  test('stream start waits for preview and ignores its late dismissal',
      () async {
    const black = PrivacySettings(PrivacyMode.black);
    await black.save();
    final previewRequested = Completer<int>();
    final reply = Completer<void>();
    beforeShowReply = (call) async {
      if (call.arguments['live'] == false) {
        previewRequested.complete(curtainId(call));
        await reply.future;
      }
    };

    final preview = service.preview(black);
    final previewId = await previewRequested.future;
    streaming = true;
    final poll = service.poll();
    final close = service.closePreview();
    reply.complete();
    await Future.wait([preview, poll, close]);

    final shows = calls.where((call) => call.method == 'showPrivacyScreen');
    expect(shows.map((call) => call.arguments['live']), [false, true]);
    expect(service.previewing.value, isFalse);
    expect(calls.where((call) => call.method == 'hidePrivacyScreen'),
        hasLength(1));
    service.dismissed(previewId);
    await service.poll();
    expect(calls.last.method, 'renewPrivacyScreen');
    service.dismissed(curtainId(shows.last));
    await service.poll();
    expect(calls.last.method, 'sunshineStreaming');
  });

  test('tray stop releases a preview whose native reply is pending', () async {
    final previewRequested = Completer<void>();
    final reply = Completer<void>();
    beforeShowReply = (_) async {
      previewRequested.complete();
      await reply.future;
    };
    final preview = service.preview(const PrivacySettings(PrivacyMode.black));
    await previewRequested.future;
    final stop = service.stop();
    reply.complete();
    await Future.wait([preview, stop]);
    expect(service.previewing.value, isFalse);
    expect(calls.last.method, 'hidePrivacyScreen');
  });

  test('preview stays closed if the runner dismisses it before replying',
      () async {
    beforeShowReply = (call) async => service.dismissed(curtainId(call));
    await service.preview(const PrivacySettings(PrivacyMode.black));
    expect(service.previewing.value, isFalse);
  });
}
