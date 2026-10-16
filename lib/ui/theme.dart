import 'package:flutter/material.dart';

/// The app theme. Placeholder look; the visual redesign replaces this file.
ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFF2B35A), brightness: b);
  return ThemeData(
    colorScheme: b == Brightness.dark ? scheme.copyWith(surface: const Color(0xFF12111C)) : scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
  );
}
