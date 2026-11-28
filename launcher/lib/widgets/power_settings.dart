import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_transfer_host.dart';
import '../services/power_service.dart';
import 'lulu_ui.dart';

class PowerSettings extends StatefulWidget {
  const PowerSettings({super.key});

  @override
  State<PowerSettings> createState() => _PowerSettingsState();
}

class _PowerSettingsState extends State<PowerSettings> {
  final _access = PowerAccess.instance;
  final _host = FileTransferHost.instance;
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _change(() async {
      final enabled = await _access.isEnabled();
      if (mounted) setState(() => _enabled = enabled);
    });
  }

  Future<void> _change(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } on Object {
      if (mounted) showLuluSnack(context, '无法完成远程电源设置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(bool rotate) async {
    final code = rotate ? await _host.rotatePowerCode() : await _access.code();
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showLuluSnack(context, rotate ? '已复制新电源码。' : '已复制电源码。');
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('远程电源'),
            subtitle: const Text('允许组网中的授权设备重启、关机和注销。'),
            value: _enabled ?? false,
            onChanged: _busy || _enabled == null
                ? null
                : (value) => _change(() async {
                      await _host.setPowerEnabled(value);
                      if (mounted) setState(() => _enabled = value);
                    }),
          ),
          if (_enabled == true)
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                  onPressed: _busy ? null : () => _change(() => _copy(false)),
                  child: const Text('复制电源码')),
              TextButton(
                  onPressed: _busy ? null : () => _change(() => _copy(true)),
                  child: const Text('更换电源码')),
            ]),
        ]),
      );
}

class PowerConfirmation extends StatefulWidget {
  const PowerConfirmation(
      {super.key,
      required this.action,
      required this.deviceName,
      required this.code});

  final PowerAction action;
  final String deviceName;
  final String code;

  @override
  State<PowerConfirmation> createState() => _PowerConfirmationState();
}

class _PowerConfirmationState extends State<PowerConfirmation> {
  late final _code = TextEditingController(text: widget.code);

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('确认${widget.action.label}「${widget.deviceName}」？'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('此操作会断开该电脑的远程连接。请先保存正在处理的文件。'),
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '电源码'),
                onChanged: (_) => setState(() {}),
              ),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: _code.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, _code.text.trim()),
              child: Text('确认${widget.action.label}')),
        ],
      );
}
