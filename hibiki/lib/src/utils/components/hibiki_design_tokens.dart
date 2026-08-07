import 'package:flutter/material.dart';

/// 预留文字块高度时统一加的余量（行高取整、字体 metrics 与理论值的零头）。
const double kTextBlockSlack = 4.0;

/// 一行 [style] 文字在当前文字缩放下占的实际高度。
///
/// BUG-1184：有一类布局必须**先给出**「能放下 N 行文字」的固定高度——网格的
/// `mainAxisExtent`、横滑行的 `SizedBox`、卡片封面下方的文字块，Flutter 都要求
/// 高度先于内容确定。此前每个这样的地方各自猜一个行高系数（最常见的错法是硬编码
/// 1.3），而 MD3 排版里 `bodyLarge` 的行高是 1.5、`labelMedium` 是 1.33——猜低了
/// 就竖向溢出，表现为「书名第二行的下半截被切掉」。
///
/// 这里统一读 [TextStyle.height] 的真实值，只有当 style 自己没声明行高时才退回一个
/// 偏保守（宁可高一点）的系数。配合 [kTextBlockSlack] 使用。
double textLineHeight(BuildContext context, TextStyle style) {
  final double fontSize = style.fontSize ?? 14.0;
  final double factor = style.height ?? 1.4;
  return MediaQuery.textScalerOf(context).scale(fontSize) * factor;
}

class FushiDesignTokens {
  const FushiDesignTokens({
    required this.radii,
    required this.surfaces,
    required this.type,
    required this.spacing,
    required this.density,
  });

  final FushiRadii radii;
  final FushiSurfaceColors surfaces;
  final FushiTypeRoles type;
  final FushiSpacingTokens spacing;
  final FushiDensityTokens density;

  // HBK-AUDIT-150: `of` is named like an O(1) lookup but used to build a fresh
  // token graph (11 Color reads + 6 TextStyle.copyWith allocations) on every
  // call — i.e. on every build of every component that reads it, several of
  // which call it more than once per build. ColorScheme/TextTheme are immutable
  // and Theme.of returns the same instance until the theme changes, so we
  // memoize by (scheme, textTheme) identity: the graph is rebuilt only when the
  // theme actually changes, and repeat calls within a frame return the cache.
  static ColorScheme? _cachedScheme;
  static TextTheme? _cachedTextTheme;
  static FushiDesignTokens? _cached;

  static FushiDesignTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;
    final FushiDesignTokens? cached = _cached;
    if (cached != null &&
        identical(_cachedScheme, scheme) &&
        identical(_cachedTextTheme, textTheme)) {
      return cached;
    }
    final FushiDesignTokens tokens = FushiDesignTokens(
      radii: const FushiRadii(),
      surfaces: FushiSurfaceColors.fromScheme(scheme),
      type: FushiTypeRoles.fromTheme(theme),
      spacing: const FushiSpacingTokens(),
      density: const FushiDensityTokens(),
    );
    _cachedScheme = scheme;
    _cachedTextTheme = textTheme;
    _cached = tokens;
    return tokens;
  }
}

class FushiRadii {
  const FushiRadii({
    this.group = groupValue,
    this.card = cardValue,
    this.control = controlValue,
    this.chip = chipValue,
    this.menu = menuValue,
    this.dialog = dialogValue,
    this.sheet = sheetValue,
  });

  // Single value source for the radii scale (used by both these field defaults
  // and [FushiBorderRadius]'s const BorderRadius objects).
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
/// `FushiDesignTokens.of(context)` would not). Values come from [FushiRadii].
abstract final class FushiBorderRadius {
  static const BorderRadius group =
      BorderRadius.all(Radius.circular(FushiRadii.groupValue));
  static const BorderRadius card =
      BorderRadius.all(Radius.circular(FushiRadii.cardValue));
  static const BorderRadius poster =
      BorderRadius.all(Radius.circular(FushiRadii.posterValue));
  static const BorderRadius control =
      BorderRadius.all(Radius.circular(FushiRadii.controlValue));
  static const BorderRadius chip =
      BorderRadius.all(Radius.circular(FushiRadii.chipValue));
  static const BorderRadius menu =
      BorderRadius.all(Radius.circular(FushiRadii.menuValue));
  static const BorderRadius dialog =
      BorderRadius.all(Radius.circular(FushiRadii.dialogValue));
  static const BorderRadius sheet =
      BorderRadius.vertical(top: Radius.circular(FushiRadii.sheetValue));
  static const Radius chipCorner = Radius.circular(FushiRadii.chipValue);
}

class FushiSurfaceColors {
  const FushiSurfaceColors({
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

  factory FushiSurfaceColors.fromScheme(ColorScheme scheme) {
    return FushiSurfaceColors(
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

class FushiTypeRoles {
  const FushiTypeRoles({
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

  factory FushiTypeRoles.fromTheme(ThemeData theme) {
    final TextTheme textTheme = theme.textTheme;
    final ColorScheme scheme = theme.colorScheme;
    return FushiTypeRoles(
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

class FushiSpacingTokens {
  const FushiSpacingTokens({
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

class FushiDensityTokens {
  const FushiDensityTokens({
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
class FushiTypeSpec {
  const FushiTypeSpec(
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
abstract final class FushiTypeScale {
  static const FushiTypeSpec displayLarge =
      FushiTypeSpec(40, FontWeight.w400, 1.15, -0.25);
  static const FushiTypeSpec displayMedium =
      FushiTypeSpec(33, FontWeight.w400, 1.16);
  static const FushiTypeSpec displaySmall =
      FushiTypeSpec(28, FontWeight.w400, 1.18);
  static const FushiTypeSpec headlineLarge =
      FushiTypeSpec(24, FontWeight.w600, 1.25);
  static const FushiTypeSpec headlineMedium =
      FushiTypeSpec(22, FontWeight.w600, 1.27);
  static const FushiTypeSpec headlineSmall =
      FushiTypeSpec(20, FontWeight.w600, 1.3);
  static const FushiTypeSpec titleLarge =
      FushiTypeSpec(18, FontWeight.w600, 1.33);
  static const FushiTypeSpec titleMedium =
      FushiTypeSpec(16, FontWeight.w600, 1.4);
  static const FushiTypeSpec titleSmall =
      FushiTypeSpec(15, FontWeight.w600, 1.4);
  static const FushiTypeSpec bodyLarge =
      FushiTypeSpec(17, FontWeight.w400, 1.5);
  static const FushiTypeSpec bodyMedium =
      FushiTypeSpec(15, FontWeight.w400, 1.5);
  static const FushiTypeSpec bodySmall =
      FushiTypeSpec(13, FontWeight.w400, 1.45);
  static const FushiTypeSpec labelLarge =
      FushiTypeSpec(13, FontWeight.w500, 1.4);
  static const FushiTypeSpec labelMedium =
      FushiTypeSpec(12, FontWeight.w500, 1.35);
  static const FushiTypeSpec labelSmall =
      FushiTypeSpec(11, FontWeight.w500, 1.45);

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
