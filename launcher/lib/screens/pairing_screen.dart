import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../pairing/pairing_errors.dart';
import '../pairing/pairing_service.dart';
import '../services/component_installer.dart';
import '../services/mesh_status_service.dart';
import '../services/moonlight_launcher.dart';
import '../services/secure_store.dart';
import '../widgets/pin_display.dart';

/// In-app pairing screen. The whole point: the user never opens Moonlight.
///
/// 1. Enter the Sunshine admin username/password for this attempt.
/// 2. Tap 开始配对. LULU generates a 4-digit PIN, shows it here, starts
///    the phase-1 /pair request, and submits the PIN to Sunshine itself.
/// 3. Wait for phases 2–5. On success the device comes back paired with
///    its AppId + host UUID resolved, and the home screen can connect.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.device});
  final Device device;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _secureStore = SecureStore();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  String? _message;
  String? _pin;
  String? _error;
  bool _running = false;
  PairingPhase? _phase;

  @override
  void initState() {
    super.initState();
    _loadSavedUser();
  }

  Future<void> _loadSavedUser() async {
    final user = await _secureStore.readSunshineUser(widget.device.id);
    if (user != null && mounted) {
      _userController.text = user;
    }
  }

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final user = _userController.text.trim();
    final password = _passwordController.text;
    if (user.isEmpty || password.isEmpty) {
      setState(() {
        _phase = null;
        _error = '请输入对方电脑的远程管理账号和密码。';
      });
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _pin = null;
    });

    try {
      _showProgress(const PairingProgress(
        PairingPhase.checkingClient,
        '正在查找本机的 Moonlight 连接组件。',
      ));
      final launcher = MoonlightLauncher();
      if (!await launcher.isInstalled()) {
        if (mounted && Platform.isWindows) {
          _showProgress(const PairingProgress(
            PairingPhase.checkingClient,
            '本机缺少 Moonlight，正在准备连接组件。',
          ));
          final result = await ComponentInstaller().prepareWindowsController();
          if (!await launcher.isInstalled()) throw PairingTransport(result);
        } else {
          throw const PairingTransport('本机缺少 Moonlight。请在连接设置中安装连接组件。');
        }
      }
      if (!mounted) return;
      _showProgress(const PairingProgress(
        PairingPhase.checkingNetwork,
        '正在检查能否连到对方的地址和远程连接端口。',
      ));
      await _checkNetwork();
      if (!mounted) return;
      final service = PairingService(secureStore: _secureStore);
      final result = await service.pair(
        device: widget.device,
        adminUser: user,
        adminPassword: password,
        onProgress: _showProgress,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('LULU 配对成功'),
          content: Text(
              Platform.isAndroid ? '需先在 Moonlight 内配对一次（验证中）。' : '现在可以回首页点连接。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(result.device);
    } on PairingException catch (error) {
      _fail(error.message);
    } on HttpException catch (error) {
      _fail(error.message);
    } on TimeoutException {
      _fail('等待对方响应超时。请确认被控电脑在线，再重试当前步骤。');
    } on SocketException {
      _fail('连接中断。请确认两台电脑的网络仍然连接，再重试。');
    } catch (_) {
      _fail('这一步未能完成。请重试，或在连接设置里检查组件。');
    }
  }

  void _showProgress(PairingProgress progress) {
    if (!mounted) return;
    setState(() {
      _phase = progress.phase;
      _message = progress.message;
      _pin = progress.pin;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = message;
    });
  }

  Future<void> _checkNetwork() async {
    final device = widget.device;
    final address = InternetAddress.tryParse(device.meshAddress);
    final octets = address?.rawAddress;
    final tailscaleAddress = octets != null &&
        octets.length == 4 &&
        octets[0] == 100 &&
        octets[1] >= 64 &&
        octets[1] <= 127;
    try {
      final socket = await Socket.connect(
        device.meshAddress,
        device.sunshinePort,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
    } on SocketException {
      final target = '${device.meshAddress}:${device.sunshinePort}';
      if (tailscaleAddress &&
          Platform.isWindows &&
          await MeshStatusService().localMeshAddress() == null) {
        throw PairingTransport('本机未取得 Tailscale 地址。请先连接跨网网络，再重试 $target。');
      }
      throw PairingTransport(tailscaleAddress
          ? '连不上 $target。请确认两台电脑登录同一个 Tailscale 网络，地址填的是被控电脑的跨网地址，且对方已开启远程控制。'
          : '连不上 $target。请核对被控电脑的地址，确认两台电脑能互通，且对方已开启远程控制。');
    }
  }

  static const _steps = {
    PairingPhase.checkingClient: '本机连接组件',
    PairingPhase.checkingNetwork: '网络与对方地址',
    PairingPhase.checkingHost: '对方远程服务（Sunshine）',
    PairingPhase.checkingAccount: '对方管理账号与访问权限',
    PairingPhase.starting: '准备本机配对身份',
    PairingPhase.waitingForPin: '等待对方收到配对请求',
    PairingPhase.submittingPin: '提交四位配对码',
    PairingPhase.challenging: '交换配对信息',
    PairingPhase.verifying: '验证身份与配对码',
    PairingPhase.confirmingTls: '确认对方已授权',
    PairingPhase.saving: '保存配对信息',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('首次连接 · ${widget.device.name}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                '请在对方的同意下，使用那台电脑的远程管理账号完成首次授权。',
                style: TextStyle(color: LuluTheme.muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _userController,
                enabled: !_running,
                decoration: const InputDecoration(
                  labelText: '对方电脑的管理账号',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                enabled: !_running,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '对方电脑的管理密码',
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _running ? null : _start,
                child: Text(_running ? '正在验证…' : '确认授权'),
              ),
              if (_running && _pin != null) ...[
                const SizedBox(height: 16),
                PinDisplay(
                  pin: _pin!,
                  subtitle: 'LULU 会自动提交此 PIN。',
                ),
              ],
              const SizedBox(height: 20),
              Text('连接进度', style: Theme.of(context).textTheme.titleMedium),
              Text('目标：${widget.device.meshAddress}',
                  style: const TextStyle(color: LuluTheme.muted)),
              if (_phase != PairingPhase.done &&
                  (_phase != null || _error != null))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error == null
                        ? '${_steps[_phase]}：${_message ?? ''}'
                        : _phase == null
                            ? _error!
                            : '${_steps[_phase]}失败：$_error',
                    style: TextStyle(
                      color: _error == null
                          ? LuluTheme.text
                          : LuluTheme.warningText,
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              for (final (index, step) in _steps.entries.indexed)
                _buildStep(index, step),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(int index, MapEntry<PairingPhase, String> step) {
    final phase = _phase;
    final passed = phase != null && phase.index > step.key.index;
    final current = phase == step.key;
    final failed = current && _error != null;
    final label = failed
        ? '失败'
        : passed
            ? '通过'
            : current
                ? '检查中'
                : '待检查';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 20,
      leading: current && _running
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              failed
                  ? Icons.error_outline
                  : passed
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
              size: 20,
              color: failed
                  ? LuluTheme.warningText
                  : passed
                      ? LuluTheme.accent
                      : LuluTheme.muted),
      title: Text('${index + 1}. ${step.value}'),
      subtitle: current
          ? Text(failed ? _error! : _message ?? '',
              style:
                  failed ? const TextStyle(color: LuluTheme.warningText) : null)
          : null,
      trailing: Text(label),
    );
  }
}
