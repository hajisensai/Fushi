import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 「玻璃」设计系统的 Apple 设计语言色板（iOS 26 / macOS 26 系统色）。
///
/// 玻璃设计系统不是「MD3 + 半透明」：内容层是 Apple 的实色分组底（浅色
/// #F2F2F7 / 深色纯黑），卡片与分组是二级分组底（白 / #1C1C1E），玻璃只留给
/// 浮在内容上的导航与控件层（侧栏、标签栏、顶栏按钮、菜单、对话框）。
/// MD3 的 tonal 容器色阶（偏蓝 / 偏绿的 container）在这里一律换成 Apple 的
/// 中性灰阶，强调色取用户主题色的色相、按 iOS 系统色的饱和度重建
/// （MD3 深色 primary 是浅粉彩，Apple 的 accent 是高饱和实色）。
///
/// 值取自 Apple HIG「Color」的 UIKit 系统色（动态色的 light / dark 两档）。
@immutable
class FushiAppleColors extends ThemeExtension<FushiAppleColors> {
  const FushiAppleColors({
    required this.accent,
    required this.onAccent,
    required this.groupedBackground,
    required this.secondaryGroupedBackground,
    required this.tertiaryGroupedBackground,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.opaqueSeparator,
    required this.fill,
    required this.secondaryFill,
    required this.tertiaryFill,
    required this.destructive,
    required this.success,
    required this.warning,
  });

  /// 按亮度生成整套系统色；[accent] 已是 iOS 化的强调色（见 [appleAccentFrom]）。
  factory FushiAppleColors.of(Brightness brightness, Color accent) {
    final bool dark = brightness == Brightness.dark;
    return FushiAppleColors(
      accent: accent,
      onAccent: appleOnAccent(accent),
      // 页面底：白底黑字 / 黑底白字（用户 2026-10-04 定调）。卡片与分组靠一层
      // 系统灰从页面底里拉开：浅色 #F2F2F7、深色 #1C1C1E。
      groupedBackground: dark
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF),
      secondaryGroupedBackground: dark
          ? const Color(0xFF1C1C1E)
          : const Color(0xFFF2F2F7),
      tertiaryGroupedBackground: dark
          ? const Color(0xFF2C2C2E)
          : const Color(0xFFE5E5EA),
      label: dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      secondaryLabel: dark ? const Color(0x99EBEBF5) : const Color(0x993C3C43),
      tertiaryLabel: dark ? const Color(0x4DEBEBF5) : const Color(0x4D3C3C43),
      separator: dark ? const Color(0x99545458) : const Color(0x4A3C3C43),
      opaqueSeparator: dark ? const Color(0xFF38383A) : const Color(0xFFC6C6C8),
      fill: dark ? const Color(0x5C787880) : const Color(0x33787880),
      secondaryFill: dark ? const Color(0x52787880) : const Color(0x29787880),
      tertiaryFill: dark ? const Color(0x3D767680) : const Color(0x1F767680),
      destructive: dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
      success: dark ? const Color(0xFF30D158) : const Color(0xFF34C759),
      warning: dark ? const Color(0xFFFF9F0A) : const Color(0xFFFF9500),
    );
  }

  final Color accent;

  /// 强调色上的前景（主按钮文字、勾、设置图标字形）：按强调色明暗取黑 / 白——
  /// 默认单色主题深色下强调色是白，前景必须是黑。
  final Color onAccent;

  /// 页面底（systemGroupedBackground）。
  final Color groupedBackground;

  /// 分组 / 卡片底（secondarySystemGroupedBackground）。
  final Color secondaryGroupedBackground;

  /// 分组内再嵌一层（tertiarySystemGroupedBackground）。
  final Color tertiaryGroupedBackground;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;

  /// 半透明细分隔线（行间、分组内）。
  final Color separator;
  final Color opaqueSeparator;

  /// 控件填充（搜索框、未选中分段、灰按钮底）：systemFill 三档。
  final Color fill;
  final Color secondaryFill;
  final Color tertiaryFill;
  final Color destructive;
  final Color success;
  final Color warning;

  @override
  FushiAppleColors copyWith({Color? accent}) => FushiAppleColors(
    accent: accent ?? this.accent,
    onAccent: accent == null ? onAccent : appleOnAccent(accent),
    groupedBackground: groupedBackground,
    secondaryGroupedBackground: secondaryGroupedBackground,
    tertiaryGroupedBackground: tertiaryGroupedBackground,
    label: label,
    secondaryLabel: secondaryLabel,
    tertiaryLabel: tertiaryLabel,
    separator: separator,
    opaqueSeparator: opaqueSeparator,
    fill: fill,
    secondaryFill: secondaryFill,
    tertiaryFill: tertiaryFill,
    destructive: destructive,
    success: success,
    warning: warning,
  );

  @override
  FushiAppleColors lerp(FushiAppleColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return FushiAppleColors(
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      groupedBackground: l(groupedBackground, other.groupedBackground),
      secondaryGroupedBackground: l(
        secondaryGroupedBackground,
        other.secondaryGroupedBackground,
      ),
      tertiaryGroupedBackground: l(
        tertiaryGroupedBackground,
        other.tertiaryGroupedBackground,
      ),
      label: l(label, other.label),
      secondaryLabel: l(secondaryLabel, other.secondaryLabel),
      tertiaryLabel: l(tertiaryLabel, other.tertiaryLabel),
      separator: l(separator, other.separator),
      opaqueSeparator: l(opaqueSeparator, other.opaqueSeparator),
      fill: l(fill, other.fill),
      secondaryFill: l(secondaryFill, other.secondaryFill),
      tertiaryFill: l(tertiaryFill, other.tertiaryFill),
      destructive: l(destructive, other.destructive),
      success: l(success, other.success),
      warning: l(warning, other.warning),
    );
  }
}

/// 当前主题的 Apple 系统色；非玻璃设计系统下按 [ColorScheme] 现算一份
/// （调用方不必判空）。
FushiAppleColors appleColorsOf(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return theme.extension<FushiAppleColors>() ??
      FushiAppleColors.of(
        theme.colorScheme.brightness,
        appleAccentFrom(
          theme.colorScheme.primary,
          theme.colorScheme.brightness,
        ),
      );
}

/// 「恒深色」的 Apple 系统色：漫画阅读器 chrome、视频控件、页图上的空状态这类
/// 永远压在黑底 / 画面上的控件层，不随 app 亮暗换色——浅色 app 里照样要深色档
/// （白字、深色填充）。强调色跟随 app：单色强调色（浅黑 / 深白）在深色档一律取
/// 白；有彩强调色保留色相、按深色档（tone 60）重建明度。app 本就是深色时直接
/// 返回当前色板。
FushiAppleColors appleDarkColorsOf(BuildContext context) {
  final FushiAppleColors current = appleColorsOf(context);
  if (Theme.of(context).colorScheme.brightness == Brightness.dark) {
    return current;
  }
  return FushiAppleColors.of(
    Brightness.dark,
    appleDarkTierAccent(current.accent),
  );
}

/// [appleDarkColorsOf] 的强调色换算（导出给需要单独换算强调色的调用点）。
Color appleDarkTierAccent(Color accent) {
  final int argb = accent.toARGB32();
  if (argb == 0xFF000000 || argb == 0xFFFFFFFF) return Colors.white;
  return appleAccentFrom(accent, Brightness.dark);
}

/// 把主题色转成 iOS 系统色风格的强调色：保留色相，饱和度拉到系统色水准，
/// 明度定在 iOS systemBlue 那一档（浅色 tone 50、深色 tone 60），白字可读。
/// 近乎无彩的主题色（灰阶主题）回落到 systemBlue。
Color appleAccentFrom(Color primary, Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  final Hct hct = Hct.fromInt(primary.toARGB32());
  if (hct.chroma < 8) {
    return dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
  }
  return Color(
    Hct.from(hct.hue, math.max(hct.chroma, 72), dark ? 60 : 50).toInt(),
  );
}

/// 强调色上的前景色（黑 / 白二选一，按强调色明暗）。
Color appleOnAccent(Color accent) =>
    ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
    ? Colors.white
    : Colors.black;

/// 默认主题的单色强调色：浅色黑、深色白（iOS 单色界面，白底黑字 / 黑底白字）。
Color appleMonochromeAccent(Brightness brightness) =>
    brightness == Brightness.dark ? Colors.white : Colors.black;

/// 不透明地叠色（把半透明系统色压平到底色上，给只收不透明色的 MD3 槽位用）。
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// 玻璃设计系统的 [ColorScheme]：以 [base] 的亮度与色相为种子，所有表面 /
/// 文字 / 描边槽位换成 Apple 系统色。MD3 组件主题读这些槽位，因此仍走 Material
/// 渲染的少数表面也自动是 Apple 观感。
///
/// [monochrome]（默认主题）：强调色取单色（浅色黑 / 深色白），不从主题色派生。
ColorScheme appleColorScheme(ColorScheme base, {bool monochrome = false}) {
  final Brightness b = base.brightness;
  final bool dark = b == Brightness.dark;
  final Color accent = monochrome
      ? appleMonochromeAccent(b)
      : appleAccentFrom(base.primary, b);
  final Color onAccent = appleOnAccent(accent);
  final FushiAppleColors a = FushiAppleColors.of(b, accent);
  final Color bg = a.groupedBackground;
  final Color card = a.secondaryGroupedBackground;
  final Color raised = dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
  final Color raisedHigh = dark
      ? const Color(0xFF3A3A3C)
      : const Color(0xFFD1D1D6);
  final Color tintedAccent = monochrome
      ? _over(a.fill, card)
      : _over(accent.withValues(alpha: dark ? 0.26 : 0.14), card);
  final Color fillOpaque = _over(a.fill, card);
  return base.copyWith(
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: tintedAccent,
    onPrimaryContainer: accent,
    primaryFixed: tintedAccent,
    primaryFixedDim: tintedAccent,
    onPrimaryFixed: accent,
    onPrimaryFixedVariant: accent,
    inversePrimary: accent,
    // 选中态底（导航选中行、选中 chip、分段选中）：Apple 用中性灰填充 +
    // 强调色图标 / 文字，不是 MD3 的 tonal 彩色容器。
    secondary: accent,
    onSecondary: onAccent,
    secondaryContainer: fillOpaque,
    onSecondaryContainer: a.label,
    tertiary: a.warning,
    onTertiary: Colors.white,
    tertiaryContainer: _over(a.warning.withValues(alpha: 0.18), card),
    onTertiaryContainer: a.warning,
    error: a.destructive,
    onError: Colors.white,
    errorContainer: _over(a.destructive.withValues(alpha: 0.18), card),
    onErrorContainer: a.destructive,
    surface: bg,
    onSurface: a.label,
    onSurfaceVariant: _over(a.secondaryLabel, card),
    surfaceDim: bg,
    surfaceBright: card,
    surfaceContainerLowest: bg,
    surfaceContainerLow: card,
    surfaceContainer: card,
    surfaceContainerHigh: raised,
    surfaceContainerHighest: raisedHigh,
    outline: a.opaqueSeparator,
    outlineVariant: a.opaqueSeparator,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: dark ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E),
    onInverseSurface: dark ? Colors.black : Colors.white,
    surfaceTint: Colors.transparent,
  );
}

/// Apple 设计系统的字阶：把 [base]（Material 字阶，携带 locale 字体链 / 基线 /
/// 颜色）换成 [FushiAppleTypeScale] 的 HIG 字号、行高与字重——组件取的仍是同
/// 15 个 TextTheme 槽位，Apple 下拿到的就是 Body 17 / Headline 17 semibold /
/// Large Title 34 bold 这套。SF 的 tracking 只在 Apple 平台的拉丁 UI 上加，
/// CJK 一律 0（套到 CJK 字形上会让字挤在一起）。
TextTheme appleTextTheme(TextTheme base) {
  final TextStyle? body = base.bodyMedium;
  final TextStyle seed = TextStyle(
    color: body?.color,
    fontFamily: body?.fontFamily,
    fontFamilyFallback: body?.fontFamilyFallback,
    fontFeatures: body?.fontFeatures,
    locale: body?.locale,
    textBaseline: body?.textBaseline,
    decorationColor: body?.decorationColor,
  );
  return FushiAppleTypeScale.buildTextTheme(seed);
}
