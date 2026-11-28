import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../services/activation_service.dart';
import '../services/machine_code_service.dart';

class ActivationScreen extends StatefulWidget {
  const ActivationScreen(
      {super.key,
      required this.service,
      required this.state,
      required this.onActivated,
      required this.onRetry});

  final ActivationService service;
  final ActivationState state;
  final ValueChanged<ActivationState> onActivated;
  final VoidCallback onRetry;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _key = TextEditingController();
  final _server = TextEditingController();
  bool _busy = false;
  ActivationError? _error;

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    try {
      final address = await widget.service.server();
      if (mounted && _server.text.isEmpty) _server.text = address;
    } catch (_) {
      // The address can still be entered manually.
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _activate(MachineFingerprint? machine) async {
    if (machine == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result =
          await widget.service.activate(_key.text, _server.text, machine);
      if (mounted) {
        _key.clear();
        widget.onActivated(result);
      }
    } on ActivationFailure catch (failure) {
      if (mounted) setState(() => _error = failure.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    final machine = widget.state.machine;
    final error = _error ?? widget.state.error;
    return Scaffold(
      appBar: AppBar(title: const Text('激活 强哥远程')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('本机机器码'),
                        if (machine != null)
                          Row(children: [
                            Expanded(
                                child: SelectableText(machine.code,
                                    style: LuluTheme.mono)),
                            IconButton(
                              tooltip: '复制机器码',
                              onPressed: () async {
                                await Clipboard.setData(
                                    ClipboardData(text: machine.code));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('机器码已复制')));
                                }
                              },
                              icon: const Icon(Icons.copy_outlined),
                            ),
                          ])
                        else
                          Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                  onPressed: widget.onRetry,
                                  child: const Text('重新检测'))),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _key,
                          enabled: !_busy && machine != null,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          style: LuluTheme.mono,
                          decoration: const InputDecoration(
                              labelText: '激活密钥',
                              hintText: 'LULU-XXXX-XXXX-XXXX-XXXX'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _server,
                          enabled: !_busy,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                              labelText: '激活服务器地址', hintText: '组网 IP:端口'),
                          onSubmitted: (_) => _activate(machine),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Semantics(
                              liveRegion: true,
                              child: Text(error.message,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: _busy || machine == null
                                ? null
                                : () => _activate(machine),
                            child: Text(_busy ? '正在激活…' : '激活')),
                        const SizedBox(height: 10),
                        Text('激活需要联网一次，激活后断网也能用。',
                            style: TextStyle(color: theme.muted)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
