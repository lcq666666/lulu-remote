import 'package:flutter/material.dart';

import '../app.dart';

/// The four digits supplied by the real pairing request.
class PinDisplay extends StatelessWidget {
  const PinDisplay({super.key, required this.pin, this.subtitle});

  final String pin;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    return Column(children: [
      Semantics(
        label: '配对 PIN 码 ${pin.split('').join(' ')}',
        excludeSemantics: true,
        child: Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Row(children: [
            for (final (index, digit) in pin.split('').indexed) ...[
              if (index > 0) const SizedBox(width: 12),
              Expanded(
                  child: Container(
                height: 62,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: theme.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color:
                            theme.isDark ? theme.border : theme.hoverBorder)),
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(digit,
                        style: LuluTheme.mono.copyWith(
                            fontSize: 28, fontWeight: FontWeight.w600))),
              )),
            ],
          ]),
        )),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 16),
        Text(subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.muted, fontSize: 13)),
      ],
    ]);
  }
}
