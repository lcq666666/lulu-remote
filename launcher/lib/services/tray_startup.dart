import 'dart:convert';
import 'dart:io';

/// Reads the two login entries managed by the launcher and host installer.
/// Merely finding a registry value does not prove its executable is still
/// present; Windows permissions and Startup Apps still control actual launch.
class TrayStartup {
  const TrayStartup({this.run = _runRegistry, this.exists = _fileExists});

  final Future<ProcessResult> Function(List<String>) run;
  final Future<bool> Function(String) exists;

  static const _suffix = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _userKey = r'HKCU\' + _suffix;
  static const _hostKey = r'HKLM\' + _suffix;
  static const _userName = 'LULU Remote';
  static const _hostName = 'LULU Remote Host';

  Future<({bool user, bool host})> read() async {
    final entries = await Future.wait([
      _enabled(_userKey, _userName),
      _enabled(_hostKey, _hostName, registry64: true),
    ]);
    return (user: entries[0], host: entries[1]);
  }

  Future<void> setUserEnabled(bool enabled, String executable) async {
    final command = '"$executable" --tray';
    if (enabled && _parseCommand(command) == null) {
      throw StateError('应用路径太长或无效，无法设置登录时启动。');
    }
    final changed = await run([
      enabled ? 'add' : 'delete',
      _userKey,
      '/v',
      _userName,
      if (enabled) ...['/t', 'REG_SZ', '/d', command],
      '/f',
    ]);
    final configured = await _readCommand(_userKey, _userName);
    if (enabled
        ? changed.exitCode != 0 ||
            _parseCommand(configured) != executable ||
            !await exists(executable)
        : changed.exitCode != 0 || configured != null) {
      throw StateError('无法确认登录时启动设置已保存。');
    }
  }

  Future<String?> _readCommand(String key, String name,
      {bool registry64 = false}) async {
    final result = await run([
      'query',
      key,
      '/v',
      name,
      if (registry64) '/reg:64',
    ]);
    if (result.exitCode != 0) return null;
    final row = RegExp('^\\s*${RegExp.escape(name)}\\s+REG_SZ\\s+(.*)\$');
    for (final line in const LineSplitter().convert(result.stdout as String)) {
      final match = row.firstMatch(line);
      if (match != null) return match[1];
    }
    return '';
  }

  Future<bool> _enabled(String key, String name,
      {bool registry64 = false}) async {
    final executable =
        _parseCommand(await _readCommand(key, name, registry64: registry64));
    return executable != null && await exists(executable);
  }

  static String? _parseCommand(String? command) {
    if (command == null || command.trimRight().length > 260) return null;
    final match = RegExp(r'^"([a-z]:[\\/][^"\r\n]+\.exe)"[ \t]+--tray[ \t]*$',
            caseSensitive: false)
        .firstMatch(command);
    return match?[1];
  }

  static Future<ProcessResult> _runRegistry(List<String> args) {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return Process.run('$root\\System32\\reg.exe', args);
  }

  static Future<bool> _fileExists(String path) => File(path).exists();
}
