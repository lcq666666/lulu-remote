import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../services/file_transfer_host.dart';
import '../services/host_tools_service.dart';
import '../services/secure_store.dart';
import 'lulu_ui.dart';

class ClipboardSettings extends StatefulWidget {
  const ClipboardSettings({super.key});

  @override
  State<ClipboardSettings> createState() => _ClipboardSettingsState();
}

class _ClipboardSettingsState extends State<ClipboardSettings> {
  final _host = FileTransferHost.instance;
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _run(() async {
      final enabled = await _host.clipboardEnabled();
      if (mounted) setState(() => _enabled = enabled);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) showLuluSnack(context, '无法读取或更新剪贴板设置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy({bool rotate = false}) async {
    final code = await (rotate ? _host.rotateToolsCode() : _host.toolsCode());
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showLuluSnack(context, '协作码已复制。');
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('共享文本剪贴板'),
            subtitle: const Text('开启后，持协作码的控制端可手动读取或替换本机剪贴板文本。'),
            value: _enabled ?? false,
            onChanged: _busy || _enabled == null
                ? null
                : (value) => _run(() async {
                      await _host.setClipboardEnabled(value);
                      if (mounted) setState(() => _enabled = value);
                    }),
          ),
          if (_enabled == true)
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                  onPressed: _busy ? null : () => _run(_copy),
                  child: const Text('复制协作码')),
              TextButton(
                  onPressed:
                      _busy ? null : () => _run(() => _copy(rotate: true)),
                  child: const Text('更换协作码')),
            ]),
        ]),
      );
}

class ClipboardShareDialog extends StatefulWidget {
  const ClipboardShareDialog({super.key, required this.device});
  final Device device;

  @override
  State<ClipboardShareDialog> createState() => _ClipboardShareDialogState();
}

class _ClipboardShareDialogState extends State<ClipboardShareDialog> {
  final _code = TextEditingController();
  final _secure = SecureStore();
  bool _loading = true;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final code = await _secure.readToolsCode(widget.device.id);
      if (mounted) _code.text = code ?? '';
    } catch (_) {
      // The code can still be entered manually.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _exchange({required bool send}) async {
    if (_busy) return;
    final address = widget.device.meshAddress;
    final code = _code.text.trim();
    if (!isPrivateTransferAddress(address)) {
      setState(() => _message = '请使用被控电脑的组网 IPv4 地址。');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final client = HostToolsClient(address, code);
      if (send) {
        await client.writeClipboard(
            (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '');
      } else {
        final text = await client.readClipboard();
        if (!mounted) return;
        await Clipboard.setData(ClipboardData(text: text));
      }
      try {
        await _secure.writeToolsCode(widget.device.id, code);
      } catch (_) {
        // The transfer succeeded even if the code could not be saved.
      }
      if (mounted) {
        setState(() => _message = send ? '文本已送到被控端剪贴板。' : '文本已复制到本机剪贴板。');
      }
    } on HostToolsException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法访问系统剪贴板。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text('文本剪贴板 · ${widget.device.displayName}'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('先在被控端打开「共享文本剪贴板」。发送或接收会替换目标设备的剪贴板文本。'),
              const SizedBox(height: 12),
              TextField(
                  controller: _code,
                  enabled: !_busy && !_loading,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '协作码')),
              if (_busy) const LinearProgressIndicator(),
              if (_message case final message?)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(message)),
            ]),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('关闭')),
          OutlinedButton(
              onPressed:
                  _busy || _loading ? null : () => _exchange(send: false),
              child: const Text('接收文本')),
          FilledButton(
              onPressed: _busy || _loading ? null : () => _exchange(send: true),
              child: const Text('发送本机文本')),
        ],
      );
}
