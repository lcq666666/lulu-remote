import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/device.dart';
import '../pairing/pairing_errors.dart';
import '../pairing/pairing_service.dart';
import '../services/secure_store.dart';
import '../widgets/pin_display.dart';

/// In-app pairing screen. The whole point: the user never opens Moonlight.
///
/// 1. Enter the Sunshine admin username/password once (stored only in the
///    OS secure store; the password field is never logged).
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
      setState(() => _error = '请先填 Sunshine 管理员账号和密码（只在 LULU 里用一次，存进系统安全存储）。');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _message = '正在准备配对…';
    });
    // Store the credentials before pairing starts (secure storage only).
    await _secureStore.writeSunshineUser(widget.device.id, user);
    await _secureStore.writeSunshinePassword(widget.device.id, password);

    try {
      final service = PairingService(secureStore: _secureStore);
      final result = await service.pair(
        device: widget.device,
        adminUser: user,
        adminPassword: password,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _message = progress.phase == PairingPhase.done
                ? 'LULU 配对完成。'
                : progress.message;
            if (progress.pin != null) _pin = progress.pin;
          });
        },
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
    } on PairingWrongPin {
      setState(() {
        _running = false;
        _error = 'PIN 不正确。请重试一次配对。';
      });
    } on PairingMitm catch (e) {
      setState(() {
        _running = false;
        _error = e.message;
      });
    } on PairingException catch (e) {
      setState(() {
        _running = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _running = false;
        _error = '配对失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('配对 · ${widget.device.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '不用打开 Moonlight。LULU 会在下面显示一个 4 位 PIN，'
            '并自动把它提交给对方电脑的 Sunshine，全程都在这里完成。',
            style: TextStyle(color: LuluTheme.muted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _userController,
            enabled: !_running,
            decoration: const InputDecoration(
              labelText: 'Sunshine 管理员账号',
              hintText: '第一次打开 https://对方地址:47990 时设置的账号',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            enabled: !_running,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Sunshine 管理员密码',
              hintText: '只存系统安全存储，不存明文文件',
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _running ? null : _start,
            child: Text(_running ? '配对中…' : '开始配对'),
          ),
          if (_pin != null) ...[
            const SizedBox(height: 16),
            PinDisplay(
              pin: _pin!,
              subtitle: '这个 PIN 已经由 LULU 提交给对方电脑，你不用再去别的地方输入。',
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                if (_running)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _message!,
                    style: const TextStyle(color: LuluTheme.text),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: LuluTheme.warningBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: LuluTheme.warningText),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            '注意：配对请求发出后，对方电脑的 Sunshine 会一直等着这个 PIN，'
            '中途不要关掉 LULU。如果等太久没反应，先确认对方电脑的 Sunshine '
            '正在运行、组网地址能连通，再重试。',
            style: TextStyle(color: LuluTheme.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
