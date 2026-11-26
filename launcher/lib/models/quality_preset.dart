/// Stream quality presets. Mapped to moonlight-qt CLI flags on Windows;
/// on Android Moonlight uses its own settings and LULU only picks the app,
/// so the preset is shown as a hint there.
class QualityPreset {
  const QualityPreset({
    required this.id,
    required this.label,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
  });

  final String id;
  final String label;
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;

  String get resolution => '${width}x$height';

  QualityPreset withFps(int fps) => QualityPreset(
        id: id,
        label: label,
        width: width,
        height: height,
        fps: fps,
        bitrateKbps: bitrateKbps,
      );

  /// e.g. `办公 1080p · 60fps · 15 Mbps`
  String get summary => '$label · ${fps}fps · ${bitrateKbps ~/ 1000} Mbps';

  /// moonlight-qt stream flags for this preset.
  List<String> get cliArgs => [
        '--resolution',
        resolution,
        '--fps',
        '$fps',
        '--bitrate',
        '$bitrateKbps',
      ];

  static const office1080 = QualityPreset(
    id: 'office1080',
    label: '办公 1080p',
    width: 1920,
    height: 1080,
    fps: 60,
    bitrateKbps: 15000,
  );

  static const hd1440 = QualityPreset(
    id: 'hd1440',
    label: '高清 1440p',
    width: 2560,
    height: 1440,
    fps: 60,
    bitrateKbps: 30000,
  );

  static const smooth720 = QualityPreset(
    id: 'smooth720',
    label: '流畅 720p',
    width: 1280,
    height: 720,
    fps: 30,
    bitrateKbps: 8000,
  );

  static const all = [office1080, hd1440, smooth720];
}
