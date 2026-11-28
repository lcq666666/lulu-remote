import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../services/file_transfer_host.dart';
import '../services/mesh_status_service.dart';
import '../services/wake_on_lan.dart';
import '../widgets/lulu_ui.dart';

/// Add a host: name + mesh address. No password is asked here — the
/// Sunshine admin password is entered on the pairing screen, once.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key, this.device, this.dialog = false});

  final Device? device;
  final bool dialog;

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  late final _nameController = TextEditingController(text: widget.device?.name);
  late final _addressController =
      TextEditingController(text: widget.device?.meshAddress);
  late final _sunshinePortController =
      TextEditingController(text: '${widget.device?.sunshinePort ?? 47989}');
  late final _webPortController =
      TextEditingController(text: '${widget.device?.webPort ?? 47990}');
  late final _appController =
      TextEditingController(text: widget.device?.appName ?? 'Desktop');
  late final _wakeMacController =
      TextEditingController(text: widget.device?.wakeMac);
  late final _wakeRelayController =
      TextEditingController(text: widget.device?.wakeRelayAddress);
  late NetworkKind _network = widget.device?.network ?? NetworkKind.tailscale;
  String? _error;

  bool _saving = false;

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    final appName = _appController.text.trim();
    final macText = _wakeMacController.text.trim();
    final wakeMac = WakeOnLan.normalizeMac(macText);
    if (macText.isNotEmpty && wakeMac == null) {
      setState(() => _error = '请填写有效的有线网卡 MAC 地址，例如 00:11:22:33:44:55。');
      return;
    }
    final relay = _wakeRelayController.text.trim();
    if (relay.isNotEmpty &&
        (wakeMac == null ||
            !isPrivateTransferAddress(relay) ||
            relay == address)) {
      setState(() => _error = '请填写目标电脑的 MAC 和另一台常开 Windows 的组网 IPv4。');
      return;
    }
    final sunshinePort = int.tryParse(_sunshinePortController.text.trim());
    final webPort = int.tryParse(_webPortController.text.trim());
    if (address.isEmpty || appName.isEmpty) {
      setState(() => _error = '请填写对方电脑的地址和应用名。');
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(address)) {
      setState(() => _error = '请填对方电脑显示的地址，例如 192.168.1.23。');
      return;
    }
    if (sunshinePort == null ||
        sunshinePort < 6 ||
        sunshinePort > 65535 ||
        webPort == null ||
        webPort < 1 ||
        webPort > 65535) {
      setState(() => _error = 'Sunshine 端口请填 6–65535，网页端口请填 1–65535。');
      return;
    }
    setState(() => _saving = true);
    final mesh = MeshStatusService();
    try {
      final local = await mesh.localAddresses();
      if (!mounted) return;
      if (relay.isNotEmpty && mesh.isLocalAddress(relay, local)) {
        setState(() => _error = '本机发送唤醒包时，留空转发电脑地址。');
        return;
      }
      if (mesh.isLocalAddress(address, local)) {
        setState(() => _error = MeshStatusService.selfAddressMessage);
        return;
      }
    } on Exception {
      if (mounted) setState(() => _error = '无法检查本机地址，请重试。');
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    final existing = widget.device;
    final sameHost = existing != null &&
        existing.meshAddress == address &&
        existing.sunshinePort == sunshinePort &&
        existing.webPort == webPort;
    final sameApp = sameHost && existing.appName == appName;
    Navigator.of(context).pop(
      Device(
        id: existing?.id ?? 'pc-${DateTime.now().microsecondsSinceEpoch}',
        name: name.isEmpty ? address : name,
        meshAddress: address,
        network: NetworkKind.detect(address) ?? _network,
        sunshinePort: sunshinePort,
        webPort: webPort,
        appName: appName,
        paired: sameApp && existing.paired,
        appId: sameApp ? existing.appId : null,
        hostUuid: sameHost ? existing.hostUuid : null,
        wakeMac: wakeMac,
        wakeRelayAddress: relay.isEmpty ? null : relay,
        lastSeen: sameHost ? existing.lastSeen : null,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _sunshinePortController.dispose();
    _webPortController.dispose();
    _appController.dispose();
    _wakeMacController.dispose();
    _wakeRelayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    final address = TextField(
      controller: _addressController,
      enabled: !_saving,
      autocorrect: false,
      keyboardType: TextInputType.url,
      style: LuluTheme.mono,
      decoration: const InputDecoration(
          labelText: '组网 / 局域网地址', hintText: '192.168.1.23'),
    );
    final port = TextField(
      controller: _sunshinePortController,
      enabled: !_saving,
      keyboardType: TextInputType.number,
      style: LuluTheme.mono,
      decoration: const InputDecoration(labelText: '端口'),
    );
    return LuluFormFrame(
      title: widget.device == null ? '添加电脑' : '编辑电脑',
      icon: Icons.desktop_windows_outlined,
      dialog: widget.dialog,
      children: [
        TextField(
          controller: _nameController,
          enabled: !_saving,
          decoration: const InputDecoration(
              labelText: '电脑名称（选填）', hintText: '例如：实验室主机'),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth < 290 ||
              MediaQuery.textScalerOf(context).scale(13) > 17) {
            return Column(
                children: [address, const SizedBox(height: 12), port]);
          }
          return Row(children: [
            Expanded(child: address),
            const SizedBox(width: 12),
            SizedBox(width: 100, child: port)
          ]);
        }),
        const SizedBox(height: 8),
        Text('请对方在 LULU 的「让别人连接我」中复制地址。',
            style: TextStyle(color: theme.muted, fontSize: 12)),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('高级设置', style: TextStyle(fontSize: 13)),
          childrenPadding: const EdgeInsets.only(bottom: 12),
          children: [
            DropdownButtonFormField<NetworkKind>(
              value: _network,
              decoration: const InputDecoration(labelText: '组网类型'),
              items: [
                for (final network in NetworkKind.values)
                  DropdownMenuItem(value: network, child: Text(network.label))
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _network = value);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _webPortController,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              style: LuluTheme.mono,
              decoration: const InputDecoration(labelText: 'Sunshine 网页端口'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _appController,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: '应用名'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _wakeMacController,
              enabled: !_saving,
              autocorrect: false,
              style: LuluTheme.mono,
              decoration: const InputDecoration(
                labelText: '有线网卡 MAC 地址（远程开机，选填）',
                hintText: '00:11:22:33:44:55',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _wakeRelayController,
              enabled: !_saving,
              autocorrect: false,
              style: LuluTheme.mono,
              decoration: const InputDecoration(
                labelText: '唤醒转发电脑的组网 IPv4（选填）',
                hintText: '100.64.10.20',
              ),
            ),
            const SizedBox(height: 8),
            const Text(WakeOnLan.help, style: TextStyle(fontSize: 12)),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        const Divider(),
        const SizedBox(height: 12),
        Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '正在检查…' : '保存电脑')),
            ]),
      ],
    );
  }
}
