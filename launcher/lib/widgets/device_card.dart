import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../services/mesh_status_service.dart';
import '../services/power_service.dart';
import 'lulu_ui.dart';

enum _DeviceAction { transfer, edit, delete, help, restart, shutdown, signOut }

class DeviceCard extends StatefulWidget {
  const DeviceCard(
      {super.key,
      required this.device,
      required this.status,
      this.responseTime,
      this.statusDetail,
      required this.connecting,
      required this.onConnect,
      this.mobile = false,
      this.busy = false,
      this.onTransfer,
      this.onWake,
      this.waking = false,
      this.onPower,
      this.onEdit,
      this.onDelete,
      this.onDisconnect,
      this.onAndroidHelp});

  final Device device;
  final HostStatus? status;
  final Duration? responseTime;
  final String? statusDetail;
  final bool connecting;
  final bool mobile;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback? onTransfer;
  final VoidCallback? onWake;
  final bool waking;
  final ValueChanged<PowerAction>? onPower;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onDisconnect;
  final VoidCallback? onAndroidHelp;

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool _hovered = false;

  String get _address =>
      '${widget.device.meshAddress}:${widget.device.sunshinePort}';

  void _runAction(_DeviceAction action) {
    switch (action) {
      case _DeviceAction.restart:
        widget.onPower?.call(PowerAction.restart);
      case _DeviceAction.shutdown:
        widget.onPower?.call(PowerAction.shutdown);
      case _DeviceAction.signOut:
        widget.onPower?.call(PowerAction.signOut);
      case _DeviceAction.transfer:
        widget.onTransfer?.call();
      case _DeviceAction.edit:
        widget.onEdit?.call();
      case _DeviceAction.delete:
        widget.onDelete?.call();
      case _DeviceAction.help:
        widget.onAndroidHelp?.call();
    }
  }

  Future<void> _showActions() async {
    final action = await showModalBottomSheet<_DeviceAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final theme = LuluTheme.of(context);
        final error = Theme.of(context).colorScheme.error;
        return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.device.name,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600)),
                            Text(_address,
                                style: LuluTheme.mono.copyWith(
                                    color: theme.muted, fontSize: 12)),
                          ]),
                    ),
                    const Divider(),
                    if (widget.onTransfer != null)
                      ListTile(
                        leading: const Icon(Icons.upload_file_outlined),
                        title: const Text('发送文件'),
                        onTap: () =>
                            Navigator.pop(context, _DeviceAction.transfer),
                      ),
                    if (widget.onEdit != null)
                      ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: const Text('编辑'),
                          onTap: () =>
                              Navigator.pop(context, _DeviceAction.edit)),
                    if (widget.onAndroidHelp != null)
                      ListTile(
                          leading: const Icon(Icons.help_outline),
                          title: const Text('连接遇到问题'),
                          onTap: () =>
                              Navigator.pop(context, _DeviceAction.help)),
                    if (widget.onPower != null)
                      for (final action in PowerAction.values)
                        ListTile(
                          leading: const Icon(Icons.power_settings_new),
                          title: Text(action.label),
                          onTap: () => Navigator.pop(context,
                              _DeviceAction.values.byName(action.name)),
                        ),
                    if (widget.onDelete != null)
                      ListTile(
                          iconColor: error,
                          textColor: error,
                          leading: const Icon(Icons.delete_outline),
                          title: const Text('删除'),
                          onTap: () =>
                              Navigator.pop(context, _DeviceAction.delete)),
                    const SizedBox(height: 8),
                    OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                  ]),
            ));
      },
    );
    if (mounted && action != null) _runAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    final error = Theme.of(context).colorScheme.error;
    final mobile = widget.mobile;
    final online = widget.status == HostStatus.online;
    final busy = widget.busy || widget.connecting || widget.waking;
    final canWake = widget.onWake != null && widget.status != null && !online;
    final responseTime = widget.responseTime;
    final statusDetail = widget.statusDetail;
    final statusColor = switch (widget.status) {
      HostStatus.online => theme.success,
      HostStatus.unreachable => theme.warning,
      _ => theme.muted,
    };
    final primary = FilledButton(
      onPressed: busy ? null : (canWake ? widget.onWake : widget.onConnect),
      style: FilledButton.styleFrom(
        minimumSize: Size(0, mobile ? 44 : 38),
        shape: mobile ? const StadiumBorder() : null,
        textStyle:
            TextStyle(fontSize: mobile ? 15 : 13, fontWeight: FontWeight.w600),
        tapTargetSize: mobile
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.connecting || widget.waking) ...[
              SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: theme.accent)),
              const SizedBox(width: 8),
            ],
            Flexible(
                child: Text(
                    widget.waking
                        ? '等待开机…'
                        : widget.connecting
                            ? '连接中…'
                            : canWake
                                ? '开机'
                                : widget.device.paired
                                    ? '进入桌面'
                                    : '首次连接',
                    textAlign: TextAlign.center)),
          ]),
    );
    final actions = widget.onPower != null ||
        widget.onTransfer != null ||
        widget.onEdit != null ||
        widget.onDelete != null ||
        widget.onAndroidHelp != null;
    return MouseRegion(
      onEnter: mobile ? null : (_) => setState(() => _hovered = true),
      onExit: mobile ? null : (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.all(mobile ? 16 : 20),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(mobile ? 14 : 10),
          border: Border.all(
              color: _hovered && !mobile ? theme.hoverBorder : theme.border),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: Text(widget.device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: mobile ? 17 : 16,
                        fontWeight: FontWeight.w600))),
            if (mobile)
              IconButton(
                  tooltip: '电脑操作',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onPressed: actions && !busy ? _showActions : null)
            else
              PopupMenuButton<_DeviceAction>(
                tooltip: '电脑操作',
                enabled: actions && !busy,
                padding: const EdgeInsets.all(4),
                icon: const Icon(Icons.more_horiz, size: 19),
                onSelected: _runAction,
                itemBuilder: (_) => [
                  if (widget.onTransfer != null)
                    const PopupMenuItem(
                        value: _DeviceAction.transfer, child: Text('发送文件')),
                  if (widget.onEdit != null)
                    const PopupMenuItem(
                        value: _DeviceAction.edit, child: Text('编辑')),
                  if (widget.onPower != null) ...[
                    const PopupMenuDivider(),
                    for (final action in PowerAction.values)
                      PopupMenuItem(
                          value: _DeviceAction.values.byName(action.name),
                          child: Text(action.label)),
                  ],
                  if (widget.onDelete != null)
                    PopupMenuItem(
                        value: _DeviceAction.delete,
                        child: Text('删除', style: TextStyle(color: error))),
                ],
              ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            LuluStatusDot(
                color: online
                    ? theme.online
                    : widget.status == HostStatus.unreachable
                        ? theme.warning
                        : theme.offline,
                glow: online),
            const SizedBox(width: 8),
            Flexible(
                child: Text(widget.status?.label ?? '尚未检查',
                    style: LuluTheme.mono
                        .copyWith(color: statusColor, fontSize: 13))),
            if (online && responseTime != null) ...[
              Text(' · ', style: TextStyle(color: theme.offline)),
              Tooltip(
                message: 'Sunshine 响应耗时（不含串流）',
                child: Text('${responseTime.inMilliseconds} ms',
                    style: LuluTheme.mono
                        .copyWith(color: theme.muted, fontSize: 13)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text(_address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LuluTheme.mono.copyWith(color: theme.muted, fontSize: 13)),
          if (statusDetail != null && statusDetail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(statusDetail,
                style: TextStyle(color: theme.muted, fontSize: 12)),
          ],
          const SizedBox(height: 20),
          if (!mobile && widget.onDisconnect != null)
            Row(children: [
              Expanded(child: primary),
              const SizedBox(width: 12),
              Expanded(
                  child: OutlinedButton(
                onPressed: busy ? null : widget.onDisconnect,
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('断开连接', textAlign: TextAlign.center),
              )),
            ])
          else
            primary,
          if (canWake && !widget.waking)
            TextButton(
              onPressed: busy ? null : widget.onConnect,
              child: const Text('直接尝试连接'),
            ),
        ]),
      ),
    );
  }
}
