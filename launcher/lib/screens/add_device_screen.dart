import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';

/// Add a host: name + mesh address. No password is asked here — the
/// Sunshine admin password is entered on the pairing screen, once.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  NetworkKind _network = NetworkKind.tailscale;
  String? _error;

  void _save() {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    if (name.isEmpty || address.isEmpty) {
      setState(() => _error = '名字和组网地址都要填。');
      return;
    }
    Navigator.of(context).pop(
      Device(
        id: 'pc-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        meshAddress: address,
        network: _network,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加电脑')),
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
            '填 Tailscale（首选）或 ZeroTier（备选）的地址。Sunshine 端口默认 '
            '47989，网页端口默认 47990，一般不用改。',
            style: TextStyle(color: LuluTheme.muted, fontSize: 12),
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
