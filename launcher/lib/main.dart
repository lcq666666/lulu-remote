import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'services/activation_service.dart';
import 'services/host_tray.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final tray = Platform.isWindows ? HostTray.instance : null;
  final activation =
      ActivationService.buildRequiresActivation ? ActivationService() : null;
  runApp(LuluApp(
    navigatorKey: tray?.navigator,
    activation: activation,
    onActivated: tray == null ? null : () => unawaited(tray.start()),
    onDeactivated: tray == null
        ? null
        : () {
            tray.stop();
            unawaited(tray.showActivation());
          },
  ));
}
