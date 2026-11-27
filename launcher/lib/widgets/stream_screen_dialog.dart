import 'package:flutter/material.dart';

class StreamScreenDialog extends StatefulWidget {
  const StreamScreenDialog({super.key, required this.streaming});

  final bool streaming;

  @override
  State<StreamScreenDialog> createState() => _StreamScreenDialogState();
}

class _StreamScreenDialogState extends State<StreamScreenDialog> {
  int _screen = 1;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('选择被控屏幕'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              value: _screen,
              decoration: const InputDecoration(labelText: 'Sunshine 屏幕编号'),
              items: [
                for (var i = 1; i <= 12; i++)
                  DropdownMenuItem(value: i, child: Text('屏幕 $i')),
              ],
              onChanged: (screen) {
                if (screen != null) setState(() => _screen = screen);
              },
            ),
            const SizedBox(height: 12),
            Text(
                '编号按被控电脑的 Sunshine 枚举顺序。也可以在 Moonlight 窗口按 Ctrl+Alt+Shift+F$_screen 切换。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _screen),
            child: Text(widget.streaming ? '切换屏幕' : '连接并切换'),
          ),
        ],
      );
}
