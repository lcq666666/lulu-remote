import 'package:flutter/material.dart';

import '../app.dart';

void showLuluSnack(BuildContext context, String message,
    {bool success = false}) {
  final theme = LuluTheme.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        Icon(success ? Icons.check_circle_outline : Icons.info_outline,
            size: 17, color: success ? theme.success : theme.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ]),
      duration: const Duration(milliseconds: 3000),
      showCloseIcon: true,
    ));
}

class LuluStatusDot extends StatelessWidget {
  const LuluStatusDot(
      {super.key, required this.color, this.glow = false, this.size = 8});

  final Color color;
  final bool glow;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: glow
              ? [BoxShadow(color: color.withOpacity(.55), blurRadius: 8)]
              : null,
        ),
      );
}

class LuluBadge extends StatelessWidget {
  const LuluBadge(
      {super.key, required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
            color: color.withOpacity(.10),
            borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4)
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: color)),
          ]),
        ),
      );
}

class LuluFormFrame extends StatelessWidget {
  const LuluFormFrame(
      {super.key,
      required this.title,
      required this.icon,
      required this.children,
      this.subtitle,
      this.dialog = false,
      this.width = 400});

  final String title;
  final IconData icon;
  final Widget? subtitle;
  final bool dialog;
  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = LuluTheme.of(context);
    final header = Row(children: [
      Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
            color: theme.accent.withOpacity(.14),
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 17, color: theme.accent),
      ),
      const SizedBox(width: 10),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        if (subtitle != null) subtitle!,
      ])),
      if (dialog)
        IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 18)),
    ]);
    final form = SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        const SizedBox(height: 20),
        ...children,
      ]),
    );
    if (dialog) {
      return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(width: width, child: form));
    }
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
            child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: Card(child: form))),
      ]),
    );
  }
}
