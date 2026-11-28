import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

enum WakeResult { online, timedOut, cancelled }

typedef LanWakeRoute = ({InternetAddress source, InternetAddress broadcast});
typedef WakeDatagramSender = Future<bool> Function(Uint8List, LanWakeRoute);

class WakeOnLan {
  static const limit = Duration(minutes: 2);
  static const timeoutMessage =
      '两分钟内未检测到远程服务。请检查是否在同一局域网、被控电脑是否接了有线网线，以及 BIOS 和网卡的网络唤醒设置。';
  static const relayTimeoutMessage =
      '转发电脑已发出唤醒包，两分钟内未检测到远程服务。请检查它是否与目标电脑同处一个局域网、目标是否接有线网线，以及 BIOS 和网卡的唤醒设置。';
  static const help =
      '同一局域网可直接唤醒。跨网时填写一台与目标同处局域网、开启唤醒转发的常开 Windows。目标电脑用有线网卡，在 BIOS/UEFI 和网卡设置中允许网络唤醒。';

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

  static LanWakeRoute? routeFor(String address, int prefix) {
    final source = InternetAddress.tryParse(address);
    if (source == null ||
        source.type != InternetAddressType.IPv4 ||
        source.isLoopback ||
        source.isMulticast ||
        prefix < 1 ||
        prefix > 30) return null;
    final raw = source.rawAddress;
    if (raw[0] == 0 || raw[0] >= 224) return null;
    final broadcast = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      final hostBits = (8 - prefix + 8 * i).clamp(0, 8);
      broadcast[i] = raw[i] | ((1 << hostBits) - 1);
    }
    if (source == InternetAddress.fromRawAddress(broadcast)) return null;
    return (
      source: source,
      broadcast: InternetAddress.fromRawAddress(broadcast)
    );
  }

  static Future<List<LanWakeRoute>> _windowsRoutes() async {
    if (!Platform.isWindows) return [];
    const channel = MethodChannel('lulu/host_tray');
    try {
      final rows = await channel.invokeListMethod<Object?>('wakeLanInterfaces');
      return [
        for (final row in rows ?? [])
          if (row is Map && row['address'] is String && row['prefix'] is int)
            if (routeFor(row['address'] as String, row['prefix'] as int)
                case final route?)
              route,
      ];
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
    }
  }

  static Future<bool> _sendDatagram(
      Uint8List payload, LanWakeRoute route) async {
    final socket = await RawDatagramSocket.bind(route.source, 0);
    try {
      socket.broadcastEnabled = true;
      return socket.send(payload, route.broadcast, 9) == payload.length;
    } finally {
      socket.close();
    }
  }

  static Future<void> send(String mac) async =>
      sendViaRoutes(packet(mac), await _windowsRoutes(), _sendDatagram);

  /// Try every distinct local route so VPN/default-route metrics don't pick
  /// the wrong LAN. Keep the original limited broadcast when no route works.
  static Future<void> sendViaRoutes(Uint8List payload,
      Iterable<LanWakeRoute> routes, WakeDatagramSender send) async {
    Future<bool> attempt(LanWakeRoute route) async {
      try {
        return await send(payload, route);
      } on SocketException {
        return false;
      }
    }

    var sent = false;
    for (final route in routes.toSet()) {
      if (await attempt(route)) sent = true;
    }
    if (!sent &&
        !await attempt((
          source: InternetAddress.anyIPv4,
          broadcast: InternetAddress('255.255.255.255'),
        ))) {
      throw const SocketException('网络未能发出唤醒包。');
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
