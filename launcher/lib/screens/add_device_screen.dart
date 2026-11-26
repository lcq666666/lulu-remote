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
    if (name.isEmpty || address.isEmpty || appName.isEmpty) {
      setState(() => _error = '名字、组网地址和应用名都要填。');
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
        name: name,
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '名字',
              hintText: '比如：远程电脑一',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _addressController,
            decoration: const InputDecoration(
              labelText: '组网地址',
              hintText: '比如：100.64.0.5（Tailscale 地址）',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<NetworkKind>(
            value: _network,
            decoration: const InputDecoration(labelText: '组网'),
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
            '填 Tailscale（首选）或 ZeroTier（备选）的地址。端口一般不用改。',
            style: TextStyle(color: LuluTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sunshinePortController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Sunshine 端口'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _webPortController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Sunshine 网页端口'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _appController,
            decoration: const InputDecoration(labelText: '串流应用名'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    );
  }
}
