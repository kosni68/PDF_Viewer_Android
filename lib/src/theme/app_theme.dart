import 'package:flutter/material.dart';

ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  const deepInk = Color(0xFF11233C);
  const gold = Color(0xFFD9B066);
  const sand = Color(0xFFF6EBDD);
  const parchment = Color(0xFFFFFBF5);
  const ember = Color(0xFFF06A4A);
  const night = Color(0xFF0C1624);

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: isDark ? gold : deepInk,
    onPrimary: isDark ? night : Colors.white,
    secondary: gold,
    onSecondary: night,
    error: ember,
    onError: Colors.white,
    surface: isDark ? night : parchment,
    onSurface: isDark ? parchment : deepInk,
    primaryContainer: isDark ? const Color(0xFF243650) : sand,
    onPrimaryContainer: isDark ? parchment : deepInk,
    secondaryContainer: isDark ? const Color(0xFF5B4A28) : const Color(0xFFF5DEAF),
    onSecondaryContainer: isDark ? parchment : night,
    errorContainer: isDark ? const Color(0xFF662E22) : const Color(0xFFF9D7CF),
    onErrorContainer: isDark ? parchment : const Color(0xFF3A1710),
    surfaceContainerHighest: isDark ? const Color(0xFF233245) : const Color(0xFFE8DED0),
    onSurfaceVariant: isDark ? const Color(0xFFDAD3CA) : const Color(0xFF5C6673),
    outline: isDark ? const Color(0xFF627184) : const Color(0xFF8C8E98),
    outlineVariant: isDark ? const Color(0xFF39485A) : const Color(0xFFD8CFC1),
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: isDark ? parchment : deepInk,
    onInverseSurface: isDark ? deepInk : parchment,
    inversePrimary: isDark ? deepInk : gold,
    surfaceTint: isDark ? gold : deepInk,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    brightness: brightness,
    scaffoldBackgroundColor: colorScheme.surface,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: isDark ? const Color(0xFF152337) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: colorScheme.outlineVariant,
        ),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      side: BorderSide(color: colorScheme.outlineVariant),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF1A273A) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colorScheme.secondary, width: 1.5),
      ),
    ),
  );
}
