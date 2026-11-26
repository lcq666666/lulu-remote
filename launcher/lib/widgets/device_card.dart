import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../models/quality_preset.dart';
import '../services/mesh_status_service.dart';

/// One host card: name, paired badge, mesh address, current preset,
/// online dot, and the connect button. Unpaired devices show the
/// in-app pairing hint instead of a bare "connect" dead end.
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.preset,
    required this.status,
    required this.connecting,
    required this.onConnect,
    required this.onPair,
    this.onEdit,
    this.onDelete,
    this.onDisconnect,
    this.onAndroidHelp,
  });

  final Device device;
  final QualityPreset preset;
  final HostStatus? status;
  final bool connecting;
  final VoidCallback onConnect;
  final VoidCallback onPair;
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
                _PairedBadge(paired: device.paired),
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
              device.meshAddress,
              style: const TextStyle(color: LuluTheme.muted),
            ),
            Text(
              '当前预设 ${preset.summary}',
              style: const TextStyle(color: LuluTheme.muted),
            ),
            if (status != null)
              Text(
                '状态：${status!.label}',
                style: const TextStyle(color: LuluTheme.muted),
              ),
            if (Platform.isAndroid || Platform.isWindows)
              Text(
                Platform.isAndroid ? '首次连接需要在手机串流应用内配对。' : '选择「进入桌面」连接这台电脑。',
                style: const TextStyle(color: LuluTheme.muted),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                ElevatedButton(
                  onPressed: connecting ? null : onConnect,
                  child: Text(connecting ? '连接中…' : '进入桌面'),
                ),
                if (onDisconnect != null)
                  OutlinedButton(
                    onPressed: connecting ? null : onDisconnect,
                    child: const Text('断开连接'),
                  ),
                if (onAndroidHelp != null)
                  TextButton(
                    onPressed: connecting ? null : onAndroidHelp,
                    child: const Text('Moonlight 连接帮助'),
                  ),
                if (!device.paired) ...[
                  TextButton(
                    onPressed: onPair,
                    child: const Text('开始配对'),
                  ),
                ],
              ],
            ),
            if (!device.paired) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: LuluTheme.warningBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '首次连接需要配对，请准备对方电脑的管理账号。',
                  style: TextStyle(color: LuluTheme.warningText),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairedBadge extends StatelessWidget {
  const _PairedBadge({required this.paired});
  final bool paired;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color:
            paired ? LuluTheme.accent.withOpacity(0.15) : LuluTheme.warningBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        paired ? '已配对' : '未配对',
        style: TextStyle(
          color: paired ? LuluTheme.accent : LuluTheme.warningText,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
