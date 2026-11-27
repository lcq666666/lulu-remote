import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class LuluTheme {
  static const background = Color(0xFFF5F7FA);
  static const surface = Colors.white;
  static const card = Colors.white;
  static const border = Color(0xFFDCE3EB);
  static const accent = Color(0xFF2364D2);
  static const accentDark = Color(0xFF174BA8);
  static const text = Color(0xFF172334);
  static const muted = Color(0xFF526378);
  static const warningBg = Color(0xFFFFF4E2);
  static const warningText = Color(0xFF815315);

  static ThemeData get theme {
    const colorScheme = ColorScheme.light(
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
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
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
  const LuluApp({super.key, this.navigatorKey});

  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LULU 远程',
      navigatorKey: navigatorKey,
      theme: LuluTheme.theme,
      debugShowCheckedModeBanner: false,
      home: const HomeScreen(),
    );
  }
}
