import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../pairing/sunshine_pin_api.dart';
import '../services/host_setup_service.dart';

class IncomingPairing extends StatefulWidget {
  const IncomingPairing({super.key, required this.checkHost});

  final Future<WindowsHostState> Function() checkHost;

  @override
  State<IncomingPairing> createState() => _IncomingPairingState();
}

class _IncomingPairingState extends State<IncomingPairing> {
  final _api = SunshinePinApi();
  final _local = Device(id: 'local', name: '本机', meshAddress: '127.0.0.1');
  final _dismissed = <String>{};
  Timer? _timer;
  ({String user, String password})? _account;
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _status = '正在检查本机远程服务…';
    });
    final state = await widget.checkHost();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = state == WindowsHostState.ready ? null : state.message;
    });
    if (state != WindowsHostState.ready) return;
    final account = await showDialog<({String user, String password})>(
      context: context,
      builder: (_) => const _PairingInputDialog(),
    );
    if (!mounted || account == null) return;
    _dismissed.clear();
    setState(() {
      _account = account;
      _status = '正在验证本机管理账号…';
    });
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    await _poll();
  }

  void _stop([String? status]) {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _account = null;
      _status = status;
    });
  }

  Future<void> _poll() async {
    final account = _account;
    if (_busy || account == null) return;
    setState(() => _busy = true);
    try {
      final requests =
          await _api.listPairings(_local, account.user, account.password);
      if (!mounted || !identical(_account, account)) return;
      _dismissed.retainAll(requests.map((request) => request.id));
      final pending =
          requests.where((request) => !_dismissed.contains(request.id));
      if (pending.isEmpty) {
        setState(
            () => _status = _dismissed.isEmpty ? '正在等待设备发起连接' : '有连接请求待确认');
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final request = pending.first;
      final approval = await showDialog<({String user, String password})>(
        context: context,
        builder: (_) => _PairingInputDialog(
          deviceName: request.name,
          address: request.address,
        ),
      );
      if (!mounted || !identical(_account, account)) return;
      if (approval == null) {
        setState(() {
          _dismissed.add(request.id);
          _status = '有连接请求待确认';
        });
        return;
      }
      setState(() => _status = '正在确认连接…');
      try {
        await _api.approveRequest(
          device: _local,
          pin: approval.password,
          adminUser: account.user,
          adminPassword: account.password,
          pairingId: request.id,
          clientName: request.name,
        );
        if (mounted) _stop('设备已配对。下次连接通常无需重新配对。');
      } catch (_) {
        if (mounted) _stop('配对未完成。请核对四位码，让对方重新发起连接。');
      }
    } on HttpException catch (error) {
      if (!mounted || !identical(_account, account)) return;
      _stop(error.message.contains('（401）')
          ? '本机管理账号或密码未通过验证。请核对后重试。'
          : '无法读取本机的连接请求。${error.message}');
    } catch (_) {
      if (mounted && identical(_account, account)) {
        _stop('无法读取本机的连接请求。请确认远程服务已开启，再重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('连接请求', style: Theme.of(context).textTheme.titleMedium),
        if (_status != null) Text(_status!),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : _account == null
                  ? _start
                  : () => _stop(),
          icon: Icon(_account == null
              ? Icons.notifications_outlined
              : Icons.stop_outlined),
          label: Text(_account == null ? '等待连接请求' : '停止等待'),
        ),
        if (_account != null && _dismissed.isNotEmpty)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    _dismissed.clear();
                    _poll();
                  },
            child: const Text('查看待确认请求'),
          ),
      ],
    );
  }
}

class _PairingInputDialog extends StatefulWidget {
  const _PairingInputDialog({this.deviceName, this.address});

  final String? deviceName;
  final String? address;

  @override
  State<_PairingInputDialog> createState() => _PairingInputDialogState();
}

class _PairingInputDialogState extends State<_PairingInputDialog> {
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _value = TextEditingController();

  @override
  void dispose() {
    _user.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final incoming = widget.deviceName != null;
    void submit() {
      if (!_form.currentState!.validate()) return;
      Navigator.pop(context, (user: _user.text.trim(), password: _value.text));
    }

    return AlertDialog(
      icon: Icon(incoming ? Icons.computer_outlined : Icons.lock_outline),
      title: Text(incoming ? '有设备请求连接' : '验证本机管理账号'),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (incoming) ...[
                  Text(widget.deviceName!,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (widget.address?.isNotEmpty == true) Text(widget.address!),
                  const SizedBox(height: 8),
                  const Text('确认你认识这台设备，再输入对方 LULU 上显示的四位码。'),
                ] else
                  TextFormField(
                    controller: _user,
                    autofocus: true,
                    decoration:
                        const InputDecoration(labelText: '本机 Sunshine 管理账号'),
                    validator: (value) =>
                        value!.trim().isEmpty ? '请输入账号' : null,
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _value,
                  autofocus: incoming,
                  obscureText: !incoming,
                  keyboardType: incoming
                      ? TextInputType.number
                      : TextInputType.visiblePassword,
                  inputFormatters: incoming
                      ? [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4)
                        ]
                      : null,
                  decoration:
                      InputDecoration(labelText: incoming ? '四位配对码' : '本机管理密码'),
                  validator: (value) => incoming
                      ? (value?.length == 4 ? null : '请输入四位配对码')
                      : (value!.isEmpty ? '请输入密码' : null),
                  onFieldSubmitted: (_) => submit(),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(incoming ? '稍后处理' : '取消'),
        ),
        FilledButton(
            onPressed: submit, child: Text(incoming ? '确认授权' : '开始等待')),
      ],
    );
  }
}
