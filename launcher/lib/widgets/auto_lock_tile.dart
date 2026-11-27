import 'package:flutter/material.dart';

import '../services/auto_lock_service.dart';
import 'lulu_ui.dart';

class AutoLockTile extends StatefulWidget {
  const AutoLockTile({super.key});

  @override
  State<AutoLockTile> createState() => _AutoLockTileState();
}

class _AutoLockTileState extends State<AutoLockTile> {
  bool? _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await AutoLockService.isEnabled();
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      // Do not let a settings read error affect the other host controls.
    }
  }

  Future<void> _change(bool enabled) async {
    setState(() => _saving = true);
    try {
      await AutoLockService.setEnabled(enabled);
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) showLuluSnack(context, '无法保存自动锁屏设置。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        title: const Text('远程结束后自动锁屏'),
        subtitle: const Text('最后一个串流断开后，锁定这台 Windows 电脑'),
        value: _enabled ?? true,
        onChanged: _enabled == null || _saving ? null : _change,
      );
}
