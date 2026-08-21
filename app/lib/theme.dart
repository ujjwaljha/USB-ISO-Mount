import 'package:flutter/material.dart';

const slate900 = Color(0xFF0F1419);
const slate800 = Color(0xFF1A2332);
const slate700 = Color(0xFF243044);
const slate600 = Color(0xFF3A4A63);
const ink = Color(0xFFE8EEF4);
const muted = Color(0xFF9AABBE);
const amber = Color(0xFFF0A202);
const amberDim = Color(0xFF8A5C00);
const sky = Color(0xFF4C9AFF);
const danger = Color(0xFFE85D4C);
const success = Color(0xFF3DDC97);

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'SF Pro Text',
  );
  return base.copyWith(
    scaffoldBackgroundColor: slate900,
    colorScheme: const ColorScheme.dark(
      primary: amber,
      onPrimary: Color(0xFF1A1200),
      secondary: sky,
      surface: slate800,
      error: danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: ink,
    ),
    cardTheme: CardThemeData(
      color: slate800,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2B394D)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: slate700,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(color: muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: amber,
        foregroundColor: const Color(0xFF1A1200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: const BorderSide(color: slate600),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
