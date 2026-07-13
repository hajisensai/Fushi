import 'dart:io' show Platform;

import 'package:flutter/material.dart';

enum HibikiDesignSystem { auto, material, cupertino, macos }

@immutable
class HibikiDesignSystemTheme extends ThemeExtension<HibikiDesignSystemTheme> {
  const HibikiDesignSystemTheme(this.designSystem);

  final HibikiDesignSystem designSystem;

  @override
  HibikiDesignSystemTheme copyWith({HibikiDesignSystem? designSystem}) {
    return HibikiDesignSystemTheme(designSystem ?? this.designSystem);
  }

  @override
  HibikiDesignSystemTheme lerp(
    covariant ThemeExtension<HibikiDesignSystemTheme>? other,
    double t,
  ) {
    return this;
  }
}

bool isCupertinoPlatform(BuildContext context) {
  final HibikiDesignSystem designSystem =
      Theme.of(context).extension<HibikiDesignSystemTheme>()?.designSystem ??
          HibikiDesignSystem.auto;
  switch (designSystem) {
    case HibikiDesignSystem.material:
      return false;
    case HibikiDesignSystem.cupertino:
      return true;
    case HibikiDesignSystem.macos:
      // Explicit macOS-native design system is NOT Cupertino. The macos_ui shell
      // and converted pages route via [isMacosPlatform]; this keeps the two
      // skins from both claiming the same surface.
      return false;
    case HibikiDesignSystem.auto:
      return false;
  }
}

/// True when the macOS-native (macos_ui) design system should drive this
/// subtree. Converted shells/pages branch on this BEFORE
/// [isCupertinoPlatform].
bool isMacosPlatform(BuildContext context) {
  final HibikiDesignSystem designSystem =
      Theme.of(context).extension<HibikiDesignSystemTheme>()?.designSystem ??
          HibikiDesignSystem.auto;
  switch (designSystem) {
    case HibikiDesignSystem.material:
    case HibikiDesignSystem.cupertino:
      return false;
    case HibikiDesignSystem.macos:
      // Explicitly selecting the macOS-native design system only routes into the
      // macos_ui / MacosWindow shell when actually running on macOS; on other
      // hosts WindowManipulator is unavailable, so fall back to the platform
      // default rather than crash. (Quality point ②)
      return Platform.isMacOS;
    case HibikiDesignSystem.auto:
      return false;
  }
}

bool get isCupertinoDefault => false;
