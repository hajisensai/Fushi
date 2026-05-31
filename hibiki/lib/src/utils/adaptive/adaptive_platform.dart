import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum HibikiDesignSystem { auto, material, cupertino }

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
    case HibikiDesignSystem.auto:
      break;
  }

  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

bool get isCupertinoDefault {
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}
