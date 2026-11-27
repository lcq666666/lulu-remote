import 'dart:async';
import 'dart:io';

/// Each request selects a fixed query. The controller supplies neither a
/// program path nor command-line arguments.
enum RemoteCommand {
  hostname('hostname', '电脑名称'),
  version('ver', 'Windows 版本'),
  user('whoami', '当前 Windows 用户');

  const RemoteCommand(this.command, this.label);
  final String command;
  final String label;

  static RemoteCommand? parse(String command) {
    for (final value in values) {
      if (value.command == command) return value;
    }
    return null;
  }

  static Future<String> runOnWindows(RemoteCommand query) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final systemDirectory = '$systemRoot\\System32';
    final (program, args) = switch (query) {
      RemoteCommand.hostname => ('hostname.exe', const <String>[]),
      RemoteCommand.version => ('cmd.exe', const ['/d', '/c', 'ver']),
      RemoteCommand.user => ('whoami.exe', const <String>[]),
    };
    final process = await Process.start('$systemDirectory\\$program', args,
        workingDirectory: systemDirectory);
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    final stderr = process.stderr.transform(systemEncoding.decoder).join();
    try {
      final parts =
          await Future.wait<Object>([process.exitCode, stdout, stderr])
              .timeout(const Duration(seconds: 4));
      final exitCode = parts[0] as int;
      final output = (parts[1] as String).trim();
      final error = (parts[2] as String).trim();
      return [
        if (output.isNotEmpty) output,
        if (error.isNotEmpty) error,
        '退出码：$exitCode',
      ].join('\n');
    } on TimeoutException {
      process.kill();
      return '命令执行超时。';
    }
  }
}
