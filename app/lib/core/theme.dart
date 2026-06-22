import 'package:flutter/material.dart';

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1E5BE6),
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1E5BE6),
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
}
