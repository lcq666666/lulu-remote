// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:lulu_pairing_worker/pairing_worker.dart';

Future<void> main() async {
  // Refuse a console or redirected file. A parent must provide anonymous pipes
  // so identity fields never print to a terminal or get saved to a file.
  if (stdin.hasTerminal ||
      stdout.hasTerminal ||
      stdioType(stdin) != StdioType.pipe ||
      stdioType(stdout) != StdioType.pipe) {
    exitCode = 64;
    return;
  }
  await for (final request
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    await runPairingRequest(request, (reply) => stdout.writeln(reply));
    await stdout.flush();
    break;
  }
}
