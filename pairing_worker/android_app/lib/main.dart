// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lulu_pairing_worker/pairing_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lulu.remote/pairing_worker_engine');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'run') throw MissingPluginException();
    // MethodChannel and the Binder pipe are ordered. Wait for pending replies
    // before completing the request so the engine can be disposed safely.
    var sent = Future<void>.value();
    await runPairingRequest(call.arguments as String, (reply) {
      sent = sent.then((_) => channel.invokeMethod<void>('reply', reply));
    });
    await sent;
  });
  await channel.invokeMethod<void>('ready');
}
