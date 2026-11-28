import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_transfer_host.dart';
import 'lulu_ui.dart';

class FileTransferSettings extends StatefulWidget {
  const FileTransferSettings({super.key});

  @override
  State<FileTransferSettings> createState() => _FileTransferSettingsState();
}

class _FileTransferSettingsState extends State<FileTransferSettings> {
  final _host = FileTransferHost.instance;
  bool? _enabled;
  bool _busy = false;
  String? _folder;

  @override
  void initState() {
    super.initState();
    _run(() async {
      final enabled = await _host.isEnabled();
      if (mounted) setState(() => _enabled = enabled);
      final folder = await _host.directoryPath();
      if (mounted) setState(() => _folder = folder);
    });
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } on StateError catch (error) {
      if (mounted) showLuluSnack(context, error.message);
    } on Exception {
      if (mounted) showLuluSnack(context, '无法完成文件接收设置，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose() async {
    final path = await getDirectoryPath();
    if (path == null) return;
    await _host.setFolder(path);
    if (mounted) setState(() => _folder = path);
  }

  Future<void> _copyCode({bool rotate = false}) async {
    final value = rotate ? await _host.rotateCode() : await _host.code();
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showLuluSnack(context, rotate ? '新接收码已复制，旧码失效。' : '接收码已复制。');
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('文件接收'),
              subtitle: const Text('同一组网中的设备可凭接收码发送文件。'),
              value: _enabled ?? false,
              onChanged: _busy || _enabled == null
                  ? null
                  : (enabled) {
                      _run(() async {
                        await _host.setEnabled(enabled);
                        if (mounted) setState(() => _enabled = enabled);
                      });
                    },
            ),
            if (_enabled == true) ...[
              if (_folder case final folder?) SelectableText(folder),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                      onPressed: _busy ? null : () => _run(_choose),
                      child: const Text('更改接收文件夹')),
                  OutlinedButton(
                      onPressed: _busy ? null : () => _run(_copyCode),
                      child: const Text('复制接收码')),
                  TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() => _copyCode(rotate: true)),
                      child: const Text('更换接收码')),
                ],
              ),
            ],
          ],
        ),
      );
}
