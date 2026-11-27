import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';

/// Add a host: name + mesh address. No password is asked here — the
/// Sunshine admin password is entered on the pairing screen, once.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key, this.device});

  final Device? device;

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
  late NetworkKind _network = widget.device?.network ?? NetworkKind.tailscale;
  String? _error;

  void _save() {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    final appName = _appController.text.trim();
    final sunshinePort = int.tryParse(_sunshinePortController.text.trim());
    final webPort = int.tryParse(_webPortController.text.trim());
    if (address.isEmpty || appName.isEmpty) {
      setState(() => _error = '请填写对方电脑的地址和应用名。');
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(address) ||
        address.toLowerCase() == 'localhost' ||
        address.startsWith('127.')) {
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
        network: _network,
        sunshinePort: sunshinePort,
        webPort: webPort,
        appName: appName,
        paired: sameApp && existing.paired,
        appId: sameApp ? existing.appId : null,
        hostUuid: sameHost ? existing.hostUuid : null,
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.device == null ? '添加电脑' : '编辑电脑')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '电脑名称（选填）',
                  hintText: '比如：远程电脑一',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: '对方电脑的地址',
                  hintText: '例如 192.168.1.23',
                  helperText: '请对方在 LULU 的「让别人连接我」中复制地址。',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              ExpansionTile(
                title: const Text('高级设置'),
                initiallyExpanded: widget.device != null &&
                    (widget.device!.sunshinePort != 47989 ||
                        widget.device!.webPort != 47990 ||
                        widget.device!.appName != 'Desktop' ||
                        widget.device!.network != NetworkKind.tailscale),
                children: [
                  DropdownButtonFormField<NetworkKind>(
                    value: _network,
                    decoration: const InputDecoration(labelText: '跨网连接方式'),
                    items: NetworkKind.values
                        .map(
                          (kind) => DropdownMenuItem(
                            value: kind,
                            child: Text(kind.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _network = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '同一个 Wi-Fi 下可直接用局域网地址。',
                    style: TextStyle(color: LuluTheme.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sunshinePortController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '远程连接端口'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _webPortController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '管理端口'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _appController,
                    decoration: const InputDecoration(labelText: '串流应用名'),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _save, child: const Text('保存')),
            ],
          ),
        ),
      ),
    );
  }
}
