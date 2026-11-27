import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/host_tray.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final tray = Platform.isWindows ? HostTray.instance : null;
  runApp(LuluApp(navigatorKey: tray?.navigator));
  if (tray != null) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(tray.start()));
  }
}
