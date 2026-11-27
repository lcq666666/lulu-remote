import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

enum WakeResult { online, timedOut, cancelled }

class WakeOnLan {
  static const limit = Duration(minutes: 2);
  static const timeoutMessage =
      '两分钟内未检测到远程服务。请检查是否在同一局域网、被控电脑是否接了有线网线，以及 BIOS 和网卡的网络唤醒设置。';
  static const help =
      '两台设备须在同一局域网，被控电脑使用有线网卡。在 BIOS/UEFI 中开启 Wake on LAN，在 Windows 网卡设置中允许魔术封包唤醒。仅通过 Tailscale 远程组网时，局域网广播无法直达。';

  static String? normalizeMac(String input) {
    final value = input.trim();
    if (!RegExp(
            r'^(?:[0-9a-f]{12}|[0-9a-f]{2}(?::[0-9a-f]{2}){5}|[0-9a-f]{2}(?:-[0-9a-f]{2}){5})$',
            caseSensitive: false)
        .hasMatch(value)) return null;
    final hex = value.replaceAll(RegExp('[:-]'), '').toUpperCase();
    if ((int.parse(hex.substring(0, 2), radix: 16) & 1) != 0 ||
        hex == '000000000000') return null;
    return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
  }

  static Uint8List packet(String mac) {
    final normalized = normalizeMac(mac);
    if (normalized == null) throw const FormatException('请填写有效的有线网卡 MAC 地址。');
    final bytes = normalized
        .split(':')
        .map((part) => int.parse(part, radix: 16))
        .toList();
    return Uint8List.fromList([
      ...List<int>.filled(6, 255),
      for (var i = 0; i < 16; i++) ...bytes,
    ]);
  }

  static Future<void> send(String mac) async {
    final payload = packet(mac);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      if (socket.send(payload, InternetAddress('255.255.255.255'), 9) !=
          payload.length) {
        throw const SocketException('网络未能发出唤醒包。');
      }
    } finally {
      socket.close();
    }
  }

  static Future<WakeResult> waitForSunshine({
    required Future<bool> Function() probe,
    required bool Function() cancelled,
    Duration timeout = limit,
    Duration interval = const Duration(seconds: 5),
  }) async {
    final timer = Stopwatch()..start();
    while (!cancelled() && timer.elapsed < timeout) {
      final remaining = timeout - timer.elapsed;
      if (remaining <= Duration.zero) break;
      final online = await probe().timeout(remaining, onTimeout: () => false);
      if (cancelled()) return WakeResult.cancelled;
      if (online) return WakeResult.online;
      final pause = math.min(
          interval.inMicroseconds, (timeout - timer.elapsed).inMicroseconds);
      if (pause > 0) await Future<void>.delayed(Duration(microseconds: pause));
    }
    return cancelled() ? WakeResult.cancelled : WakeResult.timedOut;
  }
}
