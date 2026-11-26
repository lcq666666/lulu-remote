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
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> save(List<Device> devices) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _key,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
    if (!saved) throw StateError('无法保存电脑列表。');
  }

  Future<void> deleteDevice(String id) async {
    final devices = await load();
    devices.removeWhere((device) => device.id == id);
    await save(devices);
  }

  Future<void> updateDevice(Device device) async {
    final devices = await load();
    final index = devices.indexWhere((saved) => saved.id == device.id);
    if (index == -1) throw StateError('这台电脑已不存在。');
    devices[index] = device;
    await save(devices);
  }
}
