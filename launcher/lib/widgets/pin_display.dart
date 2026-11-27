import 'package:flutter/material.dart';

import '../app.dart';

/// The code for the current pairing request.
class PinDisplay extends StatelessWidget {
  const PinDisplay({super.key, required this.pin, this.subtitle});

  final String pin;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: LuluTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LuluTheme.border),
      ),
      child: Column(
        children: [
          const Text(
            '四位配对码',
            style: TextStyle(color: LuluTheme.muted),
          ),
          const SizedBox(height: 8),
          Text(
            pin.split('').join(' '),
            style: const TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
              color: LuluTheme.accent,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: LuluTheme.muted),
            ),
          ],
        ],
      ),
    );
  }
}
