import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

CupertinoThemeData hibikiCupertinoTheme(ColorScheme scheme,
    {String? fontFamily}) {
  final brightness = scheme.brightness;
  return CupertinoThemeData(
    brightness: brightness,
    primaryColor: scheme.primary,
    primaryContrastingColor: scheme.onPrimary,
    barBackgroundColor: scheme.surface.withValues(alpha: 0.94),
    scaffoldBackgroundColor: scheme.surface,
    textTheme: CupertinoTextThemeData(
      primaryColor: scheme.primary,
      textStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: fontFamily,
        fontSize: 17,
        letterSpacing: -0.41,
      ),
      navTitleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: fontFamily,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.41,
      ),
      navLargeTitleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontFamily: fontFamily,
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.41,
      ),
    ),
  );
}
