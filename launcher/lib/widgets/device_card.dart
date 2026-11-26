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
  });

  final Device device;
  final QualityPreset preset;
  final HostStatus? status;
  final bool connecting;
  final VoidCallback onConnect;
  final VoidCallback onPair;

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
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '组网地址 ${device.meshAddress} · Sunshine 端口 ${device.sunshinePort}',
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
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: connecting ? null : onConnect,
                  child: Text(connecting ? '连接中…' : '连接'),
                ),
                if (!device.paired) ...[
                  const SizedBox(width: 12),
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
                  '这台还没配对，先做一次（约 2 分钟）：点「开始配对」，LULU 会在里面显示一个 4 位 PIN，并自动把它提交给对方电脑的 Sunshine，全程不用打开 Moonlight。',
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
        color: paired ? LuluTheme.accent.withOpacity(0.15) : LuluTheme.warningBg,
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
