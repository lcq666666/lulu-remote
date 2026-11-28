import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/tray_startup.dart';

void main() {
  const userKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  const hostKey = r'HKLM\Software\Microsoft\Windows\CurrentVersion\Run';
  const userExe = r'C:\Program Files\QG Remote\lulu_remote.exe';
  const hostExe = r'D:\Old Host\lulu_remote.exe';

  ProcessResult result(int code, [String stdout = '']) =>
      ProcessResult(1, code, stdout, '');

  test('an old host Run entry does not count when its binary is gone',
      () async {
    final startup = TrayStartup(
      run: (args) async {
        final host = args[1] == hostKey;
        expect(args, [
          'query',
          host ? hostKey : userKey,
          '/v',
          host ? 'LULU Remote Host' : 'LULU Remote',
          if (host) '/reg:64',
        ]);
        final name = args[3];
        return result(0,
            '\r\n    $name    REG_SZ    "${host ? hostExe : userExe}" --tray\r\n');
      },
      exists: (path) async => path == userExe,
    );
    expect(await startup.read(), (user: true, host: false));
  });

  test('normal GUI commands and unexpectedly typed values do not count',
      () async {
    for (final data in [
      'REG_SZ    "$userExe"',
      'REG_SZ    $userExe --tray',
      'REG_SZ    "$userExe" --tray --other',
      'REG_EXPAND_SZ    "$userExe" --tray',
    ]) {
      final startup = TrayStartup(
        run: (args) async => result(0, '    ${args[3]}    $data\n'),
        exists: (_) async => fail('no file probe for invalid Run command'),
      );
      expect(await startup.read(), (user: false, host: false), reason: data);
    }
  });

  test('setting startup saves the quoted exe and reads the value back',
      () async {
    final commands = <List<String>>[];
    String? data;
    final startup = TrayStartup(
      run: (args) async {
        commands.add(args);
        switch (args.first) {
          case 'add':
            data = args[7];
            return result(0);
          case 'delete':
            data = null;
            return result(0);
          default:
            final current = data;
            return current == null
                ? result(1)
                : result(0, '    LULU Remote    REG_SZ    $current\r\n');
        }
      },
      exists: (path) async => path == userExe,
    );
    await startup.setUserEnabled(true, userExe);
    expect(data, '"$userExe" --tray');
    await startup.setUserEnabled(false, userExe);
    expect(data, isNull);
    expect(commands.map((args) => args.first),
        ['add', 'query', 'delete', 'query']);
    expect(commands.every((args) => args[1] == userKey), isTrue);
  });

  test('a successful write alone is not enough to report enabled', () async {
    final startup = TrayStartup(
      run: (args) async => args.first == 'add' ? result(0) : result(1),
      exists: (_) async => fail('an unset command must not probe the disk'),
    );
    await expectLater(startup.setUserEnabled(true, userExe), throwsStateError);
  });
}
