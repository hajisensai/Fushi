import 'package:flutter/material.dart';

class HibikiDesignTokens {
  const HibikiDesignTokens({
    required this.radii,
    required this.surfaces,
    required this.type,
    required this.spacing,
    required this.density,
  });

  final HibikiRadii radii;
  final HibikiSurfaceColors surfaces;
  final HibikiTypeRoles type;
  final HibikiSpacingTokens spacing;
  final HibikiDensityTokens density;

  // HBK-AUDIT-150: `of` is named like an O(1) lookup but used to build a fresh
  // token graph (11 Color reads + 6 TextStyle.copyWith allocations) on every
  // call — i.e. on every build of every component that reads it, several of
  // which call it more than once per build. ColorScheme/TextTheme are immutable
  // and Theme.of returns the same instance until the theme changes, so we
  // memoize by (scheme, textTheme) identity: the graph is rebuilt only when the
  // theme actually changes, and repeat calls within a frame return the cache.
  static ColorScheme? _cachedScheme;
  static TextTheme? _cachedTextTheme;
  static HibikiDesignTokens? _cached;

  static HibikiDesignTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;
    final HibikiDesignTokens? cached = _cached;
    if (cached != null &&
        identical(_cachedScheme, scheme) &&
        identical(_cachedTextTheme, textTheme)) {
      return cached;
    }
    final HibikiDesignTokens tokens = HibikiDesignTokens(
      radii: const HibikiRadii(),
      surfaces: HibikiSurfaceColors.fromScheme(scheme),
      type: HibikiTypeRoles.fromTheme(theme),
      spacing: const HibikiSpacingTokens(),
      density: const HibikiDensityTokens(),
    );
    _cachedScheme = scheme;
    _cachedTextTheme = textTheme;
    _cached = tokens;
    return tokens;
  }
}

class HibikiRadii {
  const HibikiRadii({
    this.group = groupValue,
    this.card = cardValue,
    this.control = controlValue,
    this.chip = chipValue,
    this.menu = menuValue,
    this.dialog = dialogValue,
    this.sheet = sheetValue,
  });

  // Single value source for the radii scale (used by both these field defaults
  // and [HibikiBorderRadius]'s const BorderRadius objects).
  // Editorial scale: sharper, more geometric than M3 default (was 12/12/16/8/12/28/28).
  static const double groupValue = 10;
  static const double cardValue = 10;
  static const double controlValue = 12;
  static const double chipValue = 6;
  static const double menuValue = 10;
  static const double dialogValue = 16;
  static const double sheetValue = 16;

  /// galgame 竖版海报卡的圆角（对齐 ReinaManager 的圆润卡片观感，比 Hibiki 常规
  /// [cardValue] 稍大一档；见 `docs/design/galgame-library-reina-visual-parity.md`）。
  static const double posterValue = 16;

  final double group;
  final double card;
  final double control;
  final double chip;
  final double menu;
  final double dialog;
  final double sheet;

  BorderRadius get groupRadius => BorderRadius.circular(group);
  BorderRadius get cardRadius => BorderRadius.circular(card);
  BorderRadius get controlRadius => BorderRadius.circular(control);
  BorderRadius get chipRadius => BorderRadius.circular(chip);
  BorderRadius get menuRadius => BorderRadius.circular(menu);
  BorderRadius get dialogRadius => BorderRadius.circular(dialog);
  BorderRadius get sheetRadius =>
      BorderRadius.vertical(top: Radius.circular(sheet));
  Radius get chipCorner => Radius.circular(chip);
}

/// Compile-time `const` border radii — the single source for `BorderRadius`
/// across theme config and widget call sites. Radii are theme-independent, so
/// these stay `const`: migrating a hardcoded `BorderRadius.circular(N)` to one
/// of these preserves const-ness at the call site (routing through
/// `HibikiDesignTokens.of(context)` would not). Values come from [HibikiRadii].
abstract final class HibikiBorderRadius {
  static const BorderRadius group =
      BorderRadius.all(Radius.circular(HibikiRadii.groupValue));
  static const BorderRadius card =
      BorderRadius.all(Radius.circular(HibikiRadii.cardValue));
  static const BorderRadius poster =
      BorderRadius.all(Radius.circular(HibikiRadii.posterValue));
  static const BorderRadius control =
      BorderRadius.all(Radius.circular(HibikiRadii.controlValue));
  static const BorderRadius chip =
      BorderRadius.all(Radius.circular(HibikiRadii.chipValue));
  static const BorderRadius menu =
      BorderRadius.all(Radius.circular(HibikiRadii.menuValue));
  static const BorderRadius dialog =
      BorderRadius.all(Radius.circular(HibikiRadii.dialogValue));
  static const BorderRadius sheet =
      BorderRadius.vertical(top: Radius.circular(HibikiRadii.sheetValue));
  static const Radius chipCorner = Radius.circular(HibikiRadii.chipValue);
}

class HibikiSurfaceColors {
  const HibikiSurfaceColors({
    required this.primary,
    required this.primaryContainer,
    required this.page,
    required this.group,
    required this.card,
    required this.selected,
    required this.search,
    required this.overlay,
    required this.outline,
    required this.onSurface,
    required this.onVariant,
  });

  final Color primary;
  final Color primaryContainer;
  final Color page;
  final Color group;
  final Color card;
  final Color selected;
  final Color search;
  final Color overlay;
  final Color outline;
  final Color onSurface;
  final Color onVariant;

  factory HibikiSurfaceColors.fromScheme(ColorScheme scheme) {
    return HibikiSurfaceColors(
      primary: scheme.primary,
      primaryContainer: scheme.primaryContainer,
      page: scheme.surface,
      group: scheme.surfaceContainerLow,
      card: scheme.surfaceContainer,
      selected: scheme.secondaryContainer,
      search: scheme.surfaceContainerHigh,
      overlay: scheme.surfaceContainerHighest,
      outline: scheme.outlineVariant,
      onSurface: scheme.onSurface,
      onVariant: scheme.onSurfaceVariant,
    );
  }
}

class HibikiTypeRoles {
  const HibikiTypeRoles({
    required this.pageTitle,
    required this.listTitle,
    required this.listSubtitle,
    required this.metadata,
    required this.sectionLabel,
    required this.controlLabel,
  });

  final TextStyle pageTitle;
  final TextStyle listTitle;
  final TextStyle listSubtitle;
  final TextStyle metadata;
  final TextStyle sectionLabel;
  final TextStyle controlLabel;

  factory HibikiTypeRoles.fromTheme(ThemeData theme) {
    final TextTheme textTheme = theme.textTheme;
    final ColorScheme scheme = theme.colorScheme;
    return HibikiTypeRoles(
      listTitle: (textTheme.bodyLarge ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      listSubtitle: (textTheme.bodySmall ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      metadata: (textTheme.labelMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      pageTitle: (textTheme.headlineMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      sectionLabel: (textTheme.labelLarge ?? const TextStyle()).copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
      ),
      controlLabel: textTheme.labelLarge ?? const TextStyle(),
    );
  }
}

class HibikiSpacingTokens {
  const HibikiSpacingTokens({
    this.page = 20,
    this.rowHorizontal = 16,
    this.rowVertical = 12,
    this.card = 20,
    this.gap = 8,
    this.section = 32,
  });

  // Editorial rhythm on an 8/4px grid (was page16/rowV10/card16; rowV10 was
  // off-grid). `section` is new: spacing between major grouped sections.
  final double page;
  final double rowHorizontal;
  final double rowVertical;
  final double card;
  final double gap;
  final double section;
}

class HibikiDensityTokens {
  const HibikiDensityTokens({
    this.listMinHeight = 56,
    this.compactListMinHeight = 44,
    this.controlHeight = 48,
    this.compactControlHeight = 36,
  });

  final double listMinHeight;
  final double compactListMinHeight;
  final double controlHeight;
  final double compactControlHeight;
}

/// One role's type spec (size/weight/line-height/tracking). Applied onto the
/// locale-aware base [TextStyle] so the per-locale fontFamily/fontFeatures/
/// baseline injection is preserved while size/weight/height come from the scale.
class HibikiTypeSpec {
  const HibikiTypeSpec(
    this.size,
    this.weight,
    this.height, [
    this.letterSpacing,
  ]);

  final double size;
  final FontWeight weight;
  final double height;
  final double? letterSpacing;

  TextStyle applyTo(TextStyle base) => base.copyWith(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
      );
}

/// The app's type scale — the single source for the 15 Material text roles.
///
/// "Editorial" scale: compressed display (M3's 57 is TV-huge for a reader),
/// modular ~1.2 ratio, heavier headline/title weights for a stronger hierarchy,
/// and a slightly larger, more legible reading body. Tracking is kept at 0 for
/// most roles because the UI locale is often CJK (positive tracking spaces out
/// ideographs badly); only the single largest display size gets mild tightening.
abstract final class HibikiTypeScale {
  static const HibikiTypeSpec displayLarge =
      HibikiTypeSpec(40, FontWeight.w400, 1.15, -0.25);
  static const HibikiTypeSpec displayMedium =
      HibikiTypeSpec(33, FontWeight.w400, 1.16);
  static const HibikiTypeSpec displaySmall =
      HibikiTypeSpec(28, FontWeight.w400, 1.18);
  static const HibikiTypeSpec headlineLarge =
      HibikiTypeSpec(24, FontWeight.w600, 1.25);
  static const HibikiTypeSpec headlineMedium =
      HibikiTypeSpec(22, FontWeight.w600, 1.27);
  static const HibikiTypeSpec headlineSmall =
      HibikiTypeSpec(20, FontWeight.w600, 1.3);
  static const HibikiTypeSpec titleLarge =
      HibikiTypeSpec(18, FontWeight.w600, 1.33);
  static const HibikiTypeSpec titleMedium =
      HibikiTypeSpec(16, FontWeight.w600, 1.4);
  static const HibikiTypeSpec titleSmall =
      HibikiTypeSpec(15, FontWeight.w600, 1.4);
  static const HibikiTypeSpec bodyLarge =
      HibikiTypeSpec(17, FontWeight.w400, 1.5);
  static const HibikiTypeSpec bodyMedium =
      HibikiTypeSpec(15, FontWeight.w400, 1.5);
  static const HibikiTypeSpec bodySmall =
      HibikiTypeSpec(13, FontWeight.w400, 1.45);
  static const HibikiTypeSpec labelLarge =
      HibikiTypeSpec(13, FontWeight.w500, 1.4);
  static const HibikiTypeSpec labelMedium =
      HibikiTypeSpec(12, FontWeight.w500, 1.35);
  static const HibikiTypeSpec labelSmall =
      HibikiTypeSpec(11, FontWeight.w500, 1.45);

  /// Build the full 15-slot [TextTheme] by applying the scale onto [base]
  /// (the locale-aware app text style). Explicit sizes survive the geometry
  /// application `MaterialApp` performs (verified), so these values win.
  static TextTheme buildTextTheme(TextStyle base) => TextTheme(
        displayLarge: displayLarge.applyTo(base),
        displayMedium: displayMedium.applyTo(base),
        displaySmall: displaySmall.applyTo(base),
        headlineLarge: headlineLarge.applyTo(base),
        headlineMedium: headlineMedium.applyTo(base),
        headlineSmall: headlineSmall.applyTo(base),
        titleLarge: titleLarge.applyTo(base),
        titleMedium: titleMedium.applyTo(base),
        titleSmall: titleSmall.applyTo(base),
        bodyLarge: bodyLarge.applyTo(base),
        bodyMedium: bodyMedium.applyTo(base),
        bodySmall: bodySmall.applyTo(base),
        labelLarge: labelLarge.applyTo(base),
        labelMedium: labelMedium.applyTo(base),
        labelSmall: labelSmall.applyTo(base),
      );
}
