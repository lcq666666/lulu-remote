import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/device.dart';
import '../services/file_transfer_host.dart';
import '../services/file_transfer_service.dart';
import '../services/secure_store.dart';

class FileTransferDialog extends StatefulWidget {
  const FileTransferDialog({super.key, required this.device});
  final Device device;

  @override
  State<FileTransferDialog> createState() => _FileTransferDialogState();
}

class _FileTransferDialogState extends State<FileTransferDialog> {
  final _code = TextEditingController();
  final _client = FileTransferClient();
  final _store = SecureStore();
  XFile? _file;
  bool _sending = false;
  bool _dragging = false;
  bool _cancelled = false;
  int _total = 0;
  int _sent = 0;
  double _speed = 0;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreCode();
  }

  Future<void> _restoreCode() async {
    try {
      final value = await _store.readTransferCode(widget.device.id);
      if (mounted && !_sending && _code.text.isEmpty) _code.text = value ?? '';
    } on Exception {
      // The code can still be entered manually.
    }
  }

  @override
  void dispose() {
    _client.cancel();
    _code.dispose();
    super.dispose();
  }

  void _select(XFile file) {
    if (_sending) return;
    setState(() {
      _file = file;
      _error = null;
      _result = null;
    });
  }

  Future<void> _choose() async {
    try {
      final file = await openFile();
      if (mounted && file != null) _select(file);
    } on Exception {
      if (mounted) setState(() => _error = '无法打开文件选择器。');
    }
  }

  Future<void> _send() async {
    final file = _file;
    final code = _code.text.trim();
    final address = widget.device.meshAddress;
    if (file == null || _sending) return;
    if (!isPrivateTransferAddress(address)) {
      setState(() => _error = '请用被控电脑的组网 IPv4 地址发送文件。');
      return;
    }
    setState(() {
      _sending = true;
      _cancelled = false;
      _total = 0;
      _sent = 0;
      _speed = 0;
      _result = null;
      _error = null;
    });
    try {
      final length = await file.length();
      if (!mounted || _cancelled) return;
      setState(() => _total = length);
      final name = await _client.send(
        endpoint: Uri(scheme: 'http', host: address, port: fileTransferPort),
        code: code,
        name: file.name,
        length: length,
        openRead: file.openRead,
        onProgress: (sent, speed) {
          if (mounted && !_cancelled) {
            setState(() {
              _sent = sent;
              _speed = speed;
            });
          }
        },
      );
      if (mounted) setState(() => _result = '已发送，接收电脑保存为 $name。');
      try {
        await _store.writeTransferCode(widget.device.id, code);
      } on Exception {
        // The upload succeeded independently of remembering its code.
      }
    } on FileTransferFailure catch (failure) {
      if (mounted && !_cancelled) setState(() => _error = failure.message);
    } on Exception {
      if (mounted && !_cancelled) setState(() => _error = '无法读取这个文件。');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _cancel() {
    _client.cancel();
    setState(() {
      _cancelled = true;
      _result = '已取消。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? (_sent / _total).clamp(0.0, 1.0) : null;
    final theme = Theme.of(context);
    final picker = OutlinedButton.icon(
      onPressed: _sending ? null : _choose,
      icon: const Icon(Icons.attach_file),
      label: Text(_file?.name ?? (Platform.isWindows ? '拖放或选择文件' : '选择文件')),
    );
    return AlertDialog(
      title: Text('发送文件到 ${widget.device.name}'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _code,
                enabled: !_sending,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '接收码',
                  helperText: '由被控电脑在「文件接收」中复制。',
                ),
              ),
              const SizedBox(height: 16),
              if (Platform.isWindows)
                DropTarget(
                  onDragEntered: (_) {
                    if (!_sending) setState(() => _dragging = true);
                  },
                  onDragExited: (_) => setState(() => _dragging = false),
                  onDragDone: (details) {
                    setState(() => _dragging = false);
                    if (details.files.length == 1) {
                      _select(details.files.single);
                    } else if (!_sending) {
                      setState(() => _error = '请一次拖入一个文件。');
                    }
                  },
                  child: ColoredBox(
                    color: _dragging
                        ? theme.colorScheme.primaryContainer
                        : Colors.transparent,
                    child: SizedBox(width: double.infinity, child: picker),
                  ),
                )
              else
                picker,
              if (_sending) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _sent == 0 ? null : progress),
                const SizedBox(height: 8),
                Text(_sent == 0
                    ? '正在检查文件和接收电脑…'
                    : '${((progress ?? 0) * 100).round()}% · ${(_speed / (1024 * 1024)).toStringAsFixed(1)} MB/s'),
              ],
              if (_result case final result?) Text(result),
              if (_error case final error?)
                Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? _cancel : () => Navigator.pop(context),
          child: Text(_sending ? '取消传输' : '关闭'),
        ),
        FilledButton(
            onPressed: _sending || _file == null ? null : _send,
            child: const Text('发送')),
      ],
    );
  }
}
