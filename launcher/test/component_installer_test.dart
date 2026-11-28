import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/services/component_installer.dart';

void main() {
  test('keeps the bundled script path quoted for Start-Process', () {
    const path = r"C:\Program Files\QG's Remote\vendor\install-tailscale.ps1";
    expect(ComponentInstaller.windowsScriptArguments(path), [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '"$path"',
    ]);
  });
}
