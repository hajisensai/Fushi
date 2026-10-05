import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

CupertinoThemeData fushiCupertinoTheme(ColorScheme scheme,
    {String? fontFamily}) {
  final brightness = scheme.brightness;
  // Cupertino (iOS) chrome text follows the Apple design system's type scale
  // ([FushiAppleTypeScale], Apple HIG text styles mapped onto the 15 Material
  // roles): body = Body 17, nav title = Headline 17 semibold, large title =
  // Large Title 34 bold. Tracking follows the scale (SF tracking on Apple
  // platforms for Latin, 0 elsewhere / for CJK).
  final TextStyle base =
      TextStyle(color: scheme.onSurface, fontFamily: fontFamily);
  final TextTheme apple = FushiAppleTypeScale.buildTextTheme(base);
  return CupertinoThemeData(
    brightness: brightness,
    primaryColor: scheme.primary,
    primaryContrastingColor: scheme.onPrimary,
    barBackgroundColor: scheme.surface.withValues(alpha: 0.94),
    scaffoldBackgroundColor: scheme.surface,
    textTheme: CupertinoTextThemeData(
      primaryColor: scheme.primary,
      textStyle: apple.bodyLarge,
      navTitleTextStyle: apple.titleLarge,
      navLargeTitleTextStyle: apple.displaySmall,
    ),
  );
}
