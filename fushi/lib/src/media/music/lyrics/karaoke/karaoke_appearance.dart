/// 逐字歌词外观：调用方给的偏好（[KaraokeLyricsAppearance]，const 默认）+ 从主题解析出的
/// 实际字体颜色（[KaraokeResolvedStyle]）。颜色不写死：默认取 `ColorScheme`，歌词页铺了模糊
/// 封面背景时由调用方显式传。
library;

import 'package:material_ui/material_ui.dart';

class KaraokeLyricsAppearance {
  const KaraokeLyricsAppearance({
    this.fontSize = 30,
    this.fontWeight = FontWeight.w700,
    this.activeColor,
    this.inactiveColor,
    this.secondaryColor,
    this.showTranslation = true,
    this.showRomanization = true,
    this.showRuby = true,
    this.blurInactive = true,
    this.lineLevelSweep = true,
    this.glow = true,
    this.anchor = 0.38,
    this.rowSpacing = 34,
    this.horizontalPadding = 24,
    this.inactiveOpacity = 0.42,
    this.liftPx = 3,
  });

  /// 主行字号（逻辑像素，再乘系统文字缩放）。和声行 / 注音 / 副行按比例缩。
  final double fontSize;
  final FontWeight fontWeight;

  /// 已唱部分颜色；null = `ColorScheme.onSurface`。
  final Color? activeColor;

  /// 未唱部分颜色；null = [activeColor] 的 35% 透明度。
  final Color? inactiveColor;

  /// 翻译 / 罗马音副行颜色；null = `ColorScheme.onSurfaceVariant`。
  final Color? secondaryColor;
  final bool showTranslation;
  final bool showRomanization;
  final bool showRuby;

  /// 非当前行轻模糊。低端机由调用方关；高对比度 / 减弱动态效果 / 墨水屏自动关。
  final bool blurInactive;

  /// 行级歌词（只有行时间）整行线性擦色估计；false = 到点整行高亮。
  final bool lineLevelSweep;

  /// 当前音节辉光（Apple 风）。
  final bool glow;

  /// 当前行停在视口高度的哪个比例处（0.5 = 正中）。
  final double anchor;
  final double rowSpacing;
  final double horizontalPadding;

  /// 非当前行不透明度。
  final double inactiveOpacity;

  /// 当前音节上浮像素。
  final double liftPx;

  @override
  bool operator ==(Object other) =>
      other is KaraokeLyricsAppearance &&
      other.fontSize == fontSize &&
      other.fontWeight == fontWeight &&
      other.activeColor == activeColor &&
      other.inactiveColor == inactiveColor &&
      other.secondaryColor == secondaryColor &&
      other.showTranslation == showTranslation &&
      other.showRomanization == showRomanization &&
      other.showRuby == showRuby &&
      other.blurInactive == blurInactive &&
      other.lineLevelSweep == lineLevelSweep &&
      other.glow == glow &&
      other.anchor == anchor &&
      other.rowSpacing == rowSpacing &&
      other.horizontalPadding == horizontalPadding &&
      other.inactiveOpacity == inactiveOpacity &&
      other.liftPx == liftPx;

  @override
  int get hashCode => Object.hash(
    fontSize,
    fontWeight,
    activeColor,
    inactiveColor,
    secondaryColor,
    showTranslation,
    showRomanization,
    showRuby,
    blurInactive,
    lineLevelSweep,
    glow,
    anchor,
    rowSpacing,
    horizontalPadding,
    inactiveOpacity,
    liftPx,
  );
}

/// 排版用的已解析样式（决定 [KaraokeLineLayout] 缓存是否失效）。
@immutable
class KaraokeResolvedStyle {
  const KaraokeResolvedStyle({
    required this.main,
    required this.background,
    required this.ruby,
    required this.sub,
    required this.active,
    required this.inactive,
    required this.secondary,
    required this.textScaler,
    required this.showRuby,
    required this.showTranslation,
    required this.showRomanization,
    required this.glow,
  });

  /// 从主题解析。字体族沿用当前主题（MD3 / Apple 各自的 textTheme）。
  factory KaraokeResolvedStyle.of(
    BuildContext context,
    KaraokeLyricsAppearance a,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Color active = a.activeColor ?? cs.onSurface;
    final Color inactive =
        a.inactiveColor ?? active.withValues(alpha: active.a * 0.35);
    final Color secondary = a.secondaryColor ?? cs.onSurfaceVariant;
    final TextStyle base = (theme.textTheme.headlineSmall ?? const TextStyle())
        .copyWith(
          fontSize: a.fontSize,
          fontWeight: a.fontWeight,
          height: 1.25,
          color: null,
          decoration: TextDecoration.none,
        );
    return KaraokeResolvedStyle(
      main: base,
      background: base.copyWith(
        fontSize: a.fontSize * 0.62,
        fontWeight: FontWeight.w600,
      ),
      ruby: base.copyWith(fontSize: a.fontSize * 0.42, height: 1.1),
      sub: (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
        fontSize: a.fontSize * 0.5,
        fontWeight: FontWeight.w500,
        height: 1.15,
        color: secondary,
      ),
      active: active,
      inactive: inactive,
      secondary: secondary,
      textScaler: MediaQuery.textScalerOf(context),
      showRuby: a.showRuby,
      showTranslation: a.showTranslation,
      showRomanization: a.showRomanization,
      glow: a.glow,
    );
  }

  final TextStyle main;
  final TextStyle background;
  final TextStyle ruby;
  final TextStyle sub;
  final Color active;
  final Color inactive;
  final Color secondary;
  final TextScaler textScaler;
  final bool showRuby;
  final bool showTranslation;
  final bool showRomanization;
  final bool glow;

  @override
  bool operator ==(Object other) =>
      other is KaraokeResolvedStyle &&
      other.main == main &&
      other.background == background &&
      other.ruby == ruby &&
      other.sub == sub &&
      other.active == active &&
      other.inactive == inactive &&
      other.secondary == secondary &&
      other.textScaler == textScaler &&
      other.showRuby == showRuby &&
      other.showTranslation == showTranslation &&
      other.showRomanization == showRomanization &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(
    main,
    background,
    ruby,
    sub,
    active,
    inactive,
    secondary,
    textScaler,
    showRuby,
    showTranslation,
    showRomanization,
    glow,
  );
}
