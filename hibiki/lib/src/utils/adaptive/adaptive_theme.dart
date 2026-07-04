import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

CupertinoThemeData hibikiCupertinoTheme(ColorScheme scheme,
    {String? fontFamily}) {
  final brightness = scheme.brightness;
  // Cupertino (iOS) chrome text follows the app's editorial type scale
  // ([HibikiTypeScale]) instead of hardcoded iOS point sizes (was 17/17/34,
  // weights w400/w600/w700), so iOS matches the Material surfaces. Sizes/weights
  // come from the scale; letterSpacing comes from it too (0 for CJK safety),
  // dropping the old iOS Latin tracking (-0.41/0.41) that spaced CJK glyphs out.
  // navLargeTitle keeps a stronger weight (w600) for large-title presence.
  final TextStyle base =
      TextStyle(color: scheme.onSurface, fontFamily: fontFamily);
  return CupertinoThemeData(
    brightness: brightness,
    primaryColor: scheme.primary,
    primaryContrastingColor: scheme.onPrimary,
    barBackgroundColor: scheme.surface.withValues(alpha: 0.94),
    scaffoldBackgroundColor: scheme.surface,
    textTheme: CupertinoTextThemeData(
      primaryColor: scheme.primary,
      textStyle: HibikiTypeScale.bodyLarge.applyTo(base),
      navTitleTextStyle: HibikiTypeScale.titleLarge.applyTo(base),
      navLargeTitleTextStyle: HibikiTypeScale.displaySmall
          .applyTo(base)
          .copyWith(fontWeight: FontWeight.w600),
    ),
  );
}
