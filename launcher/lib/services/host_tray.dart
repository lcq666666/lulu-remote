import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import 'auto_lock_service.dart';
import 'file_transfer_host.dart';
import 'mesh_status_service.dart';
import 'pairing_worker_client.dart';
import 'privacy_screen_service.dart';

typedef _Account = ({String user, String password});

class HostTray {
  static final instance = HostTray._();
  HostTray._();

  final navigator = GlobalKey<NavigatorState>();
  static const _channel = MethodChannel('lulu/host_tray');
  final _api = PairingWorkerClient();
  final _autoLock = AutoLockService();
  final _local = Device(id: 'local', name: '本机', meshAddress: 'localhost');
  final _seen = <String, Duration>{};
  final _dismissed = <String>{};
  final _clock = Stopwatch()..start();
  _Account? _account;
  DialogRoute<void>? _prompt;
  bool _polling = false;
  bool _presenting = false;
  bool _registering = false;
  bool _offeredRegistration = false;
  bool _enabled = false;
  int _generation = 0;
  Timer? _timer;

  Future<void> showActivation() async {
    try {
      await _channel.invokeMethod<bool>('show');
    } on PlatformException {
      // Windows may be shutting down.
    }
  }

  void stop() {
    _enabled = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _account = null;
    _autoLock.reset();
    unawaited(FileTransferHost.instance.stop());
    unawaited(PrivacyScreenService.instance.stop());
    _seen.clear();
    _dismissed.clear();
    _offeredRegistration = false;
  }

  Future<void> start() async {
    if (_enabled) return;
    _enabled = true;
    final generation = ++_generation;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'privacyScreenDismissed') {
        if (call.arguments case final int id) {
          PrivacyScreenService.instance.dismissed(id);
        }
      } else if (call.method == 'dismissPrompt') {
        final route = _prompt;
        if (route != null && route.isCurrent) route.navigator?.pop();
      }
    });
    try {
      final stored = await _channel.invokeMethod<String>('readCredential');
      if (generation != _generation) return;
      if (stored != null) {
        final entry = jsonDecode(stored);
        if (entry is Map &&
            entry['user'] is String &&
            entry['password'] is String) {
          _account = (
            user: entry['user'] as String,
            password: entry['password'] as String
          );
        }
      }
    } on Exception {
      // The host screen can retry registration if Windows storage is unavailable.
    }
    if (generation != _generation) return;
    FileTransferHost.instance.start();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollSession());
      unawaited(_poll());
    });
    unawaited(_pollSession());
    await _poll();
  }

  Future<void> _pollSession() {
    final generation = _generation;
    return PrivacyScreenService.instance.poll(onSample: (sample) async {
      if (_enabled && generation == _generation) {
        await _autoLock.onSessionSample(sample);
      }
    });
  }

  Future<void> register() async {
    if (!_enabled || _registering || _presenting) return;
    final context = navigator.currentContext;
    if (context == null) return;
    _registering = true;
    _offeredRegistration = true;
    try {
      final account = await showDialog<_Account>(
          context: context,
          builder: (_) => _HostCredentialDialog(
              initialUser: _account?.user, save: _saveAccount));
      if (account != null) _account = account;
    } finally {
      _registering = false;
    }
  }

  Future<void> _saveAccount(_Account account) async {
    await _api.verifyAccount(
        device: _local,
        adminUser: account.user,
        adminPassword: account.password);
    await _channel.invokeMethod<void>(
        'writeCredential',
        jsonEncode({
          'user': account.user,
          'password': account.password,
        }));
  }

  Future<void> _poll() async {
    if (!_enabled || _polling || _registering) return;
    final generation = _generation;
    _polling = true;
    try {
      final account = _account;
      if (account == null) {
        if (_offeredRegistration) return;
        await MeshStatusService().verifyLocalHost();
        if (generation != _generation) return;
        await _channel.invokeMethod<bool>('show');
        unawaited(register());
        return;
      }
      final requests =
          await _api.listPairings(_local, account.user, account.password);
      if (generation != _generation || !identical(account, _account)) return;
      final ids = requests.map((request) => request.id).toSet();
      _seen.removeWhere((id, _) => !ids.contains(id));
      _dismissed.retainAll(ids);
      for (final request in requests) {
        if (!_seen.containsKey(request.id)) {
          _seen[request.id] = _clock.elapsed;
          await _channel.invokeMethod<bool>('notify');
          if (generation != _generation) return;
        }
      }
      if (_presenting || _registering) return;
      for (final request in requests) {
        if (_dismissed.contains(request.id) ||
            _clock.elapsed - _seen[request.id]! < const Duration(seconds: 10)) {
          continue;
        }
        unawaited(_showPrompt(request, account));
        break;
      }
    } on Exception {
      // A stopped service or a transient network error is retried next tick.
    } on StateError {
      // Hosting may not have been enabled on this computer yet.
    } finally {
      _polling = false;
    }
  }

  Future<void> _showPrompt(({String id, String name, String address}) request,
      _Account account) async {
    final state = navigator.currentState;
    final context = navigator.currentContext;
    if (state == null || context == null) return;
    _presenting = true;
    final generation = _generation;
    var hideAfter = false;
    try {
      hideAfter = await _channel.invokeMethod<bool>('showPrompt') ?? false;
      if (!context.mounted || generation != _generation) return;
      final name =
          request.name.replaceFirst(RegExp(r' · LULU-[a-f0-9]{32}$'), '');
      final route = DialogRoute<void>(
          context: context,
          builder: (_) => _IncomingPinDialog(
                name: name,
                address: request.address,
                confirm: (pin) async {
                  final current = await _api.listPairings(
                      _local, account.user, account.password);
                  if (generation != _generation ||
                      !current.any((entry) => entry.id == request.id)) {
                    throw const HttpException('请求已结束，请让对方重新发起。');
                  }
                  await _api.approveRequest(
                      device: _local,
                      pin: pin,
                      adminUser: account.user,
                      adminPassword: account.password,
                      pairingId: request.id,
                      clientName: name);
                },
              ));
      _prompt = route;
      await state.push(route);
    } on Exception {
      // If Windows cannot display the prompt, the next poll can retry.
      return;
    } finally {
      if (_prompt != null && _seen.containsKey(request.id)) {
        _dismissed.add(request.id);
      }
      _prompt = null;
      _presenting = false;
      try {
        await _channel.invokeMethod<void>(
            'finishPrompt', hideAfter && generation == _generation);
      } on PlatformException {
        // Windows may be shutting down.
      }
    }
  }
}

class _HostCredentialDialog extends StatefulWidget {
  const _HostCredentialDialog({this.initialUser, required this.save});
  final String? initialUser;
  final Future<void> Function(_Account) save;

  @override
  State<_HostCredentialDialog> createState() => _HostCredentialDialogState();
}

class _HostCredentialDialogState extends State<_HostCredentialDialog> {
  late final _user = TextEditingController(text: widget.initialUser);
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final account = (user: _user.text.trim(), password: _password.text);
    if (account.user.isEmpty || account.password.isEmpty) {
      setState(() => _error = '请填写这台电脑的管理账号和密码。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(account);
      if (mounted) Navigator.pop(context, account);
    } on HttpException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException {
      if (mounted) setState(() => _error = '无法保存到 Windows 凭据管理器。');
    } on Exception {
      if (mounted) setState(() => _error = '无法验证账号，请确认本机远程服务已开启。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('启用配对提醒'),
        content: SizedBox(
            width: 350,
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('登记一次这台电脑的 Sunshine 管理账号。LULU 会保存到 Windows 凭据管理器。'),
                const SizedBox(height: 12),
                TextField(
                    controller: _user,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '本机管理账号')),
                const SizedBox(height: 8),
                TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '本机管理密码')),
                if (_error != null) Text(_error!),
              ],
            ))),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('稍后设置')),
          FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? '正在验证…' : '验证并保存')),
        ],
      );
}

class _IncomingPinDialog extends StatefulWidget {
  const _IncomingPinDialog(
      {required this.name, required this.address, required this.confirm});
  final String name;
  final String address;
  final Future<void> Function(String) confirm;

  @override
  State<_IncomingPinDialog> createState() => _IncomingPinDialogState();
}

class _IncomingPinDialogState extends State<_IncomingPinDialog> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    if (_pin.text.length != 4) {
      setState(() => _error = '请输入对方电脑上显示的 4 位 PIN。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.confirm(_pin.text);
      if (mounted) Navigator.pop(context);
    } on HttpException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) setState(() => _error = '确认失败，请核对配对码或让对方重新发起。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('有设备正在请求连接')),
          IconButton(
              tooltip: '关闭',
              onPressed: _busy ? null : () => Navigator.pop(context),
              icon: const Icon(Icons.close)),
        ]),
        content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (widget.address.isNotEmpty) Text(widget.address),
                const SizedBox(height: 12),
                TextField(
                    controller: _pin,
                    autofocus: true,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4)
                    ],
                    decoration:
                        const InputDecoration(labelText: '对方电脑显示的 4 位 PIN'),
                    onSubmitted: (_) => _confirm()),
                if (_error != null) Text(_error!),
                const SizedBox(height: 12),
                const Text('关闭后请求会在一段时间后自动过期。'),
              ],
            ))),
        actions: [
          FilledButton(
              onPressed: _busy ? null : _confirm,
              child: Text(_busy ? '正在确认…' : '确认'))
        ],
      );
}
