import 'package:flutter/material.dart' show Brightness, ColorScheme;
import 'package:macos_ui/macos_ui.dart';

/// Derives a [MacosThemeData] from Hibiki's existing [ColorScheme] single source
/// of truth so the macos_ui shell tracks the same seed/brightness as the rest of
/// the app instead of carrying a second, divergent palette.
MacosThemeData hibikiMacosThemeFromColorScheme(
  ColorScheme cs,
  Brightness brightness,
) {
  final MacosThemeData base = brightness == Brightness.dark
      ? MacosThemeData.dark()
      : MacosThemeData.light();
  return base.copyWith(
    primaryColor: cs.primary,
    canvasColor: cs.surface,
  );
}
