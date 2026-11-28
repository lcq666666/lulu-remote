import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_transfer_host.dart';
import '../services/file_transfer_service.dart';
import 'lulu_ui.dart';

class WakeRelaySettings extends StatefulWidget {
  const WakeRelaySettings({super.key});

  @override
  State<WakeRelaySettings> createState() => _WakeRelaySettingsState();
}

class _WakeRelaySettingsState extends State<WakeRelaySettings> {
  final _host = FileTransferHost.instance;
  final _targets = TextEditingController();
  bool _busy = true;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final targets = await _host.wakeTargets();
      if (!mounted) return;
      _targets.text = targets.join('\n');
      setState(() {
        _enabled = targets.isNotEmpty;
        _busy = false;
      });
    } catch (_) {
      if (mounted) showLuluSnack(context, '无法读取唤醒转发设置。');
    }
  }

  Future<void> _save({required bool enable}) async {
    final targets = _targets.text
        .split(RegExp(r'[\s,，]+'))
        .where((entry) => entry.isNotEmpty);
    if (enable && targets.isEmpty) {
      showLuluSnack(context, '请先填写目标电脑的有线网卡 MAC。');
      return;
    }
    setState(() => _busy = true);
    try {
      await _host.setWakeTargets(enable ? targets : const []);
      if (mounted) {
        setState(() => _enabled = enable);
        showLuluSnack(context, enable ? '唤醒转发已开启。' : '唤醒转发已关闭。');
      }
    } on FormatException catch (error) {
      if (mounted) showLuluSnack(context, error.message);
    } catch (_) {
      if (mounted) showLuluSnack(context, '无法保存唤醒转发设置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy({bool rotate = false}) async {
    setState(() => _busy = true);
    try {
      final code = rotate
          ? await _host.rotateWakeRelayCode()
          : await _host.wakeRelayCode();
      await Clipboard.setData(ClipboardData(text: code));
      if (mounted) showLuluSnack(context, '转发电脑的唤醒转发码已复制。');
    } catch (_) {
      if (mounted) showLuluSnack(context, '无法复制唤醒转发码。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _targets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _targets,
            enabled: !_busy,
            minLines: 1,
            maxLines: 4,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '唤醒转发的目标 MAC',
              helperText: '登记本机局域网内的有线网卡，每行一个。',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
              onPressed: _busy ? null : () => _save(enable: true),
              child: Text(_enabled ? '保存唤醒目标' : '开启唤醒转发'),
            ),
            if (_enabled) ...[
              OutlinedButton(
                  onPressed: _busy ? null : _copy,
                  child: const Text('复制唤醒转发码')),
              TextButton(
                  onPressed: _busy ? null : () => _copy(rotate: true),
                  child: const Text('更换唤醒转发码')),
              TextButton(
                  onPressed: _busy ? null : () => _save(enable: false),
                  child: const Text('关闭唤醒转发')),
            ],
          ]),
        ]),
      );
}

Future<String?> askWakeRelayCode(BuildContext context, String address) {
  var code = '';
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
              title: const Text('通过常开电脑唤醒'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('输入转发电脑 $address 的唤醒转发码。'),
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '转发电脑唤醒转发码'),
                  onChanged: (value) => setState(() => code = value.trim()),
                ),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                  onPressed: validTransferCode(code)
                      ? () => Navigator.pop(context, code)
                      : null,
                  child: const Text('发送唤醒'),
                ),
              ],
            )),
  );
}
