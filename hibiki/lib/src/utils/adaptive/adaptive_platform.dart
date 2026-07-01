import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
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
      break;
  }

  // Under `auto`, macOS still resolves to Cupertino here so that pages NOT yet
  // converted to macos_ui keep rendering a coherent Cupertino skin inside the
  // MacosWindow shell (incremental-rollout fallback). Converted call sites must
  // check [isMacosPlatform] FIRST and only fall through to this for the legacy
  // skin.
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

/// True when the macOS-native (macos_ui) design system should drive this
/// subtree: either the user explicitly picked it, or we're on macOS under
/// `auto`. Converted shells/pages branch on this BEFORE [isCupertinoPlatform].
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
      break;
  }

  return Theme.of(context).platform == TargetPlatform.macOS;
}

bool get isCupertinoDefault {
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}
