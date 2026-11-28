import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum RemoteCommand {
  hostname('hostname', '电脑名称'),
  version('ver', 'Windows 版本'),
  user('whoami', '当前 Windows 用户'),
  approved('approved', '被控端预设命令');

  const RemoteCommand(this.command, this.label);
  final String command;
  final String label;

  static RemoteCommand? parse(String command) =>
      values.where((value) => value.command == command).firstOrNull;

  static const approvedTimeout = Duration(seconds: 25);

  static Future<String> runOnWindows(RemoteCommand query,
      {ApprovedWindowsCommand? approved}) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final systemDirectory = '$systemRoot\\System32';
    final (program, arguments) = switch (query) {
      RemoteCommand.hostname => ('hostname.exe', const <String>[]),
      RemoteCommand.version => ('cmd.exe', const ['/d', '/c', 'ver']),
      RemoteCommand.user => ('whoami.exe', const <String>[]),
      RemoteCommand.approved => ('', const <String>[]),
    };
    final custom = query == RemoteCommand.approved;
    if (custom && approved == null) return '被控端尚未配置预设命令。';
    final process = custom
        ? await Process.start(approved!.executable, approved.arguments,
            workingDirectory: File(approved.executable).parent.path)
        : await Process.start('$systemDirectory\\$program', arguments,
            workingDirectory: systemDirectory);
    unawaited(process.stdin.close().then<void>((_) {}, onError: (Object _) {}));
    final stdout = StreamIterator(process.stdout);
    final stderr = StreamIterator(process.stderr);
    try {
      final parts = await Future.wait<Object>([
        process.exitCode,
        _readOutput(stdout),
        _readOutput(stderr),
      ]).timeout(custom ? approvedTimeout : const Duration(seconds: 4));
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
    } finally {
      unawaited(stdout.cancel());
      unawaited(stderr.cancel());
    }
  }

  static Future<String> _readOutput(StreamIterator<List<int>> stream) async {
    const limit = 4096;
    final bytes = <int>[];
    var truncated = false;
    while (await stream.moveNext()) {
      final chunk = stream.current;
      final remaining = limit - bytes.length;
      if (chunk.length > remaining) truncated = true;
      bytes.addAll(chunk.take(remaining));
    }
    String text;
    try {
      text = systemEncoding.decode(bytes);
    } on FormatException {
      text = utf8.decode(bytes, allowMalformed: true);
    }
    return truncated ? '$text\n（输出已截断）' : text;
  }
}

class ApprovedWindowsCommand {
  ApprovedWindowsCommand(this.executable, List<String> arguments)
      : arguments = List.unmodifiable(arguments) {
    if (!_absoluteProgram.hasMatch(executable) ||
        executable.length > 260 ||
        RegExp(r'[\x00-\x1f"]').hasMatch(executable) ||
        arguments.length > 32 ||
        arguments.join().length > 1024 ||
        arguments.any((arg) => RegExp(r'[\x00-\x1f]').hasMatch(arg))) {
      throw const FormatException('请填写本机 EXE 完整路径，每行一个参数。');
    }
  }

  static final _absoluteProgram =
      RegExp(r'^[a-zA-Z]:[\\/].+\.exe$', caseSensitive: false);
  final String executable;
  final List<String> arguments;

  static ApprovedWindowsCommand? decode(String? raw) {
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    return ApprovedWindowsCommand(value['executable'] as String,
        (value['arguments'] as List<dynamic>).cast<String>());
  }

  String encode() => jsonEncode({
        'executable': executable,
        'arguments': arguments,
      });
}
