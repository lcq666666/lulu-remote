import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

/// Device list persistence (non-secret fields only).
///
/// v1 scope is 2 hosts, but the store itself holds N devices; the UI caps
/// the add-device flow at 2 so the scope stays honest.
class DeviceStore {
  static const _key = 'lulu_devices_v1';
  static const maxDevices = 2;

  Future<List<Device>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return _seed();
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => Device.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(List<Device> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
  }

  /// First-run seed: the two placeholder hosts from the research
  /// prototype. The user edits the mesh addresses to their real ones.
  /// Nothing here is a real credential.
  List<Device> _seed() => [
        Device(
          id: 'pc-1',
          name: '远程电脑一',
          meshAddress: '100.64.0.5',
          network: NetworkKind.tailscale,
        ),
        Device(
          id: 'pc-2',
          name: '远程电脑二',
          meshAddress: '100.64.0.9',
          network: NetworkKind.tailscale,
        ),
      ];
}
