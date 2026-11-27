import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../services/mesh_status_service.dart';

class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.status,
    required this.connecting,
    required this.onConnect,
    this.onEdit,
    this.onDelete,
    this.onDisconnect,
    this.onAndroidHelp,
  });

  final Device device;
  final HostStatus? status;
  final bool connecting;
  final VoidCallback onConnect;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onDisconnect;
  final VoidCallback? onAndroidHelp;

  @override
  Widget build(BuildContext context) {
    final online = status == HostStatus.online;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: online ? LuluTheme.accent : LuluTheme.muted,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    device.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: LuluTheme.text,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '电脑操作',
                  enabled: onEdit != null && onDelete != null,
                  onSelected: (action) {
                    if (action == 'edit') {
                      onEdit?.call();
                    } else {
                      onDelete?.call();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              status?.label ?? '尚未检查连接状态',
              style: const TextStyle(color: LuluTheme.muted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                ElevatedButton(
                  onPressed: connecting ? null : onConnect,
                  child: Text(connecting
                      ? '连接中…'
                      : device.paired
                          ? '进入桌面'
                          : '首次连接'),
                ),
                if (onDisconnect != null)
                  OutlinedButton(
                    onPressed: connecting ? null : onDisconnect,
                    child: const Text('断开连接'),
                  ),
                if (onAndroidHelp != null)
                  TextButton(
                    onPressed: connecting ? null : onAndroidHelp,
                    child: const Text('连接遇到问题'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
