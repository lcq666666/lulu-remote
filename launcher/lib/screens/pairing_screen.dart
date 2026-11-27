import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../models/device.dart';
import '../pairing/pairing_errors.dart';
import '../pairing/pairing_service.dart';
import '../pairing/sunshine_pin_api.dart';
import '../services/component_installer.dart';
import '../services/mesh_status_service.dart';
import '../services/moonlight_launcher.dart';
import '../services/secure_store.dart';
import '../widgets/lulu_ui.dart';
import '../widgets/pin_display.dart';

/// In-app pairing screen. The whole point: the user never opens Moonlight.
///
/// 1. Enter the Sunshine admin username/password for this attempt.
/// 2. Tap 开始配对. LULU generates a 4-digit PIN, shows it here, starts
///    the phase-1 /pair request, and submits the PIN to Sunshine itself.
/// 3. Wait for phases 2–5. On success the device comes back paired with
///    its AppId + host UUID resolved, and the home screen can connect.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.device, this.dialog = false});
  final Device device;
  final bool dialog;

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
  String? _requestName;
  String? _pinStatus;
  Timer? _waitTimer;
  final _waiting = Stopwatch();
  bool _checkingRequest = false;

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
    _waitTimer?.cancel();
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
      _requestName = null;
      _pinStatus = null;
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
    if (progress.pin != null && !_waiting.isRunning) {
      _waiting
        ..reset()
        ..start();
      _waitTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (progress.pin == null) {
      _waitTimer?.cancel();
      _waiting.stop();
    }
    setState(() {
      _phase = progress.phase;
      _message = progress.message;
      _pin = progress.pin;
      _requestName = progress.requestName;
    });
  }

  void _fail(String message) {
    _waitTimer?.cancel();
    _waiting.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = message;
    });
  }

  Future<void> _checkNetwork() async {
    final device = widget.device;
    final mesh = MeshStatusService();
    final local = await mesh.localAddresses();
    if (mesh.isLocalAddress(device.meshAddress, local)) {
      throw const PairingTransport(MeshStatusService.selfAddressMessage);
    }
    final target = '${device.meshAddress}:${device.sunshinePort}';
    final kind = NetworkKind.detect(device.meshAddress);
    Future<bool> missingNetwork() async {
      if (!Platform.isWindows || kind == null) return false;
      if (kind == NetworkKind.tailscale) {
        final connected = await mesh.tailscaleConnected();
        if (connected != null) return !connected;
      }
      return !local.any((ip) => ip.network == kind);
    }

    final timeoutMessage = '连接 $target 超时。请确认两台电脑在同一网络，并检查对方防火墙是否放行远程连接。';
    final missingMessage = '本机还没接入 ${kind?.label}。请先连接与对方相同的网络。';
    try {
      final socket = await Socket.connect(
          device.meshAddress, device.sunshinePort,
          timeout: const Duration(seconds: 5));
      socket.destroy();
    } on SocketException catch (error) {
      if (MeshStatusService.connectionRefused(error)) {
        throw PairingTransport(
            '对方拒绝 TCP 连接（$target）。请在被控电脑开启远程服务（Sunshine）并核对端口。');
      }
      if (await missingNetwork()) throw PairingTransport(missingMessage);
      final code = error.osError?.errorCode;
      if (const {60, 110, 10060}.contains(code) ||
          (code == null && error.message.toLowerCase().contains('timed out'))) {
        throw PairingTransport(timeoutMessage);
      }
      throw PairingTransport(
          '无法连接 $target。请核对对方地址和网络连接（系统错误 ${code ?? '未知'}）。');
    } on TimeoutException {
      throw PairingTransport(
          await missingNetwork() ? missingMessage : timeoutMessage);
    }
  }

  Future<void> _checkPendingRequest() async {
    final name = _requestName;
    if (name == null) return;
    setState(() => _checkingRequest = true);
    try {
      final requests = await SunshinePinApi().listPairings(
          widget.device, _userController.text.trim(), _passwordController.text);
      if (!mounted || _requestName != name) return;
      setState(() => _pinStatus =
          requests.any((request) => request.name == name)
              ? '对方仍有待确认的请求。'
              : '待确认列表里已没有这条请求，请看下方连接进度。');
    } on Exception {
      if (mounted && _requestName == name) {
        setState(() => _pinStatus = '无法查询对方的待确认请求。');
      }
    } finally {
      if (mounted) setState(() => _checkingRequest = false);
    }
  }

  Future<void> _openPairingPage() async {
    try {
      if (await launchUrl(Uri.parse(widget.device.webBase),
          mode: LaunchMode.externalApplication)) return;
    } on Exception {
      // Show the address if the browser cannot be opened.
    }
    if (mounted) {
      setState(() => _pinStatus = '无法打开浏览器。请打开 ${widget.device.webBase}。');
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
    final theme = LuluTheme.of(context);
    final device = widget.device;
    final pin = _running ? _pin : null;
    return LuluFormFrame(
      title: '首次连接配对',
      icon: Icons.verified_user_outlined,
      dialog: widget.dialog,
      width: 420,
      subtitle: Text(
          '${device.name} · ${device.meshAddress}:${device.sunshinePort}',
          style: LuluTheme.mono.copyWith(fontSize: 12, color: theme.muted)),
      children: [
        if (pin == null) ...[
          Text('请在对方同意后，使用那台电脑的远程管理账号完成首次授权。',
              style: TextStyle(color: theme.muted, fontSize: 13)),
          const SizedBox(height: 16),
          TextField(
              controller: _userController,
              enabled: !_running,
              decoration: const InputDecoration(labelText: '对方电脑的管理账号')),
          const SizedBox(height: 12),
          TextField(
              controller: _passwordController,
              enabled: !_running,
              obscureText: true,
              decoration: const InputDecoration(labelText: '对方电脑的管理密码')),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _running ? null : _start,
              child: Text(_running ? '正在验证…' : '确认授权')),
        ] else ...[
          PinDisplay(
            pin: pin,
            subtitle: 'LULU 会自动提交。需要手动确认时，请在对方电脑的配对弹窗或 Sunshine 的 PIN 页面输入此码。',
          ),
          const SizedBox(height: 12),
          Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: theme.accent)),
                Text('等待主机确认配对…',
                    style: TextStyle(color: theme.muted, fontSize: 12)),
                Text('${_waiting.elapsed.inSeconds} 秒',
                    style: LuluTheme.mono
                        .copyWith(color: theme.muted, fontSize: 12)),
              ]),
          const SizedBox(height: 8),
          Wrap(alignment: WrapAlignment.center, spacing: 6, children: [
            TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: pin));
                  if (mounted && _pin == pin) {
                    setState(() => _pinStatus = '已复制 PIN。');
                  }
                },
                child: const Text('复制 PIN')),
            TextButton(
                onPressed: _openPairingPage, child: const Text('打开对方配对页')),
            TextButton(
                onPressed: _checkingRequest ? null : _checkPendingRequest,
                child: const Text('我已在对方电脑输入')),
          ]),
          if (_pinStatus != null)
            Text(_pinStatus!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.muted, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        const Divider(),
        if (_running) const LinearProgressIndicator(minHeight: 2),
        if (_error != null || (_phase != null && _phase != PairingPhase.done))
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error == null
                        ? '${_steps[_phase] ?? '正在配对'}：${_message ?? ''}'
                        : _phase == null
                            ? _error!
                            : '${_steps[_phase]}失败：$_error',
                    style: TextStyle(
                        fontSize: 13,
                        color: _error == null ? theme.muted : theme.warning),
                  ))),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('连接进度',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          children: [
            for (final step in _steps.entries) _buildStep(step, theme)
          ],
        ),
        if (widget.dialog)
          Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'))),
      ],
    );
  }

  Widget _buildStep(MapEntry<PairingPhase, String> step, LuluTheme theme) {
    final phase = _phase;
    final passed = phase != null && phase.index > step.key.index;
    final current = phase == step.key;
    final failed = current && _error != null;
    final label = failed
        ? '失败'
        : passed
            ? '通过'
            : current && _running
                ? '检查中'
                : '待检查';
    final color = failed
        ? theme.warning
        : passed
            ? theme.success
            : current && _running
                ? theme.accent
                : theme.muted;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 18,
      leading: current && _running
          ? const SizedBox.square(
              dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(
              failed
                  ? Icons.error_outline
                  : passed
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
              size: 17,
              color: color),
      title: Text(step.value),
      trailing: LuluBadge(label: label, color: color),
    );
  }
}
