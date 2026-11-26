import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

/// LULU Remote theme — dark green/teal, like the research-page prototype.
/// One accent, one warning colour, no gradients, no clutter.
class LuluTheme {
  static const background = Color(0xFF0B1F1A);
  static const surface = Color(0xFF12261F);
  static const card = Color(0xFF16281F);
  static const border = Color(0xFF24443A);
  static const accent = Color(0xFF2DD4A7);
  static const accentDark = Color(0xFF1FA37E);
  static const text = Color(0xFFE8F2ED);
  static const muted = Color(0xFF9FB3A8);
  static const warningBg = Color(0xFF3A2E12);
  static const warningText = Color(0xFFF2C94C);

  static ThemeData get theme {
    const colorScheme = ColorScheme.dark(
      primary: accent,
      secondary: accent,
      surface: surface,
      error: Color(0xFFFF6B6B),
    );
    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      useMaterial3: true,
      fontFamily: null,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardTheme(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF06231B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: text),
      ),
    );
  }
}

class LuluApp extends StatelessWidget {
  const LuluApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LULU 远程',
      theme: LuluTheme.theme,
      debugShowCheckedModeBanner: false,
      home: const HomeScreen(),
    );
  }
}
