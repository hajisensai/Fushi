/// 带色卡片的局部配色作用域：色块（海报色块、导入页色块等）只给自己画底色时，
/// 子树里的按钮 / 开关 / 胶囊 / 图表 / 从卡里弹出的对话框都退回全局 primary /
/// tertiary（11-20 反馈：蓝灰复习卡里粉紫按钮、深蓝互联卡里紫色开关、绿色连续
/// 天数卡里紫色热力图、棕色头卡弹出灰色格式框）。[FushiBlockColorScope] 按块自己
/// 的 [FushiCoverBlockColors] 派生一整套局部主题包住子树：
/// - MD3：[ColorScheme] 的强调色族（primary / secondary / tertiary 及其容器）全换
///   成块的强调色 / 前景色，表面色阶是块底按前景色微调的同色相深浅，再经
///   [rethemeFushiWithScheme] 重走主题工厂——开关、按钮、菜单、对话框、弹层的
///   组件主题里烤进去的颜色一并换掉；
/// - Apple：[FushiAppleColors]（玻璃按钮 / 开关读的 accent、分组底、填充）同样
///   换成块配色。
/// 同时放一个 [FushiPopupOriginScope]：从块里弹出的对话框 / 底部弹层（包括经
/// 页面 State 转弹的）继承这份配色（见 `fushi_popup_origin.dart`）。
///
/// 中性块（[FushiCoverBlockColors.hue] 为 null：没封面 / 墨水屏）本来就是主题色，
/// 不包。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors;
import 'package:fushi/src/utils/components/fushi_popup_origin.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show FushiAppleColors;

/// 块配色下的 [ColorScheme]：强调色族取块的强调色（上面的字取块底色），各级
/// 容器 / 表面是块底按前景色叠 2%～16% 的同色相深浅；不出现块以外的色相。
/// 海报详情页的面板主题（`mediaPosterDetailTheme`）也用这一份。
ColorScheme fushiBlockColorScheme(
  ColorScheme base,
  FushiCoverBlockColors colors,
) {
  final Color bg = colors.container;
  final Color on = colors.onContainer;
  final Color accent = colors.accent;
  Color mix(double alpha) => Color.alphaBlend(on.withValues(alpha: alpha), bg);
  return base.copyWith(
    primary: accent,
    onPrimary: bg,
    primaryContainer: mix(0.2),
    onPrimaryContainer: on,
    primaryFixed: mix(0.2),
    primaryFixedDim: mix(0.16),
    onPrimaryFixed: on,
    onPrimaryFixedVariant: on,
    secondary: accent,
    onSecondary: bg,
    secondaryContainer: mix(0.14),
    onSecondaryContainer: on,
    secondaryFixed: mix(0.16),
    secondaryFixedDim: mix(0.12),
    onSecondaryFixed: on,
    onSecondaryFixedVariant: on,
    tertiary: accent,
    onTertiary: bg,
    tertiaryContainer: mix(0.18),
    onTertiaryContainer: on,
    tertiaryFixed: mix(0.18),
    tertiaryFixedDim: mix(0.14),
    onTertiaryFixed: on,
    onTertiaryFixedVariant: on,
    surface: bg,
    onSurface: on,
    onSurfaceVariant: mix(0.74),
    surfaceDim: mix(0.02),
    surfaceBright: mix(0.1),
    surfaceContainerLowest: mix(0.03),
    surfaceContainerLow: mix(0.06),
    surfaceContainer: mix(0.09),
    surfaceContainerHigh: mix(0.12),
    surfaceContainerHighest: mix(0.16),
    outline: mix(0.45),
    outlineVariant: mix(0.22),
    surfaceTint: accent,
    inverseSurface: on,
    onInverseSurface: bg,
    inversePrimary: bg,
  );
}

/// 块配色下的 Apple 系统色（[base] 是当前主题的 Apple 色板）。
FushiAppleColors fushiBlockAppleColors(
  FushiAppleColors base,
  FushiCoverBlockColors colors,
) {
  final Color bg = colors.container;
  final Color on = colors.onContainer;
  Color mix(double alpha) => Color.alphaBlend(on.withValues(alpha: alpha), bg);
  return FushiAppleColors(
    accent: colors.accent,
    onAccent: bg,
    groupedBackground: bg,
    secondaryGroupedBackground: mix(0.08),
    tertiaryGroupedBackground: mix(0.14),
    label: on,
    secondaryLabel: on.withValues(alpha: 0.7),
    tertiaryLabel: on.withValues(alpha: 0.4),
    separator: on.withValues(alpha: 0.18),
    opaqueSeparator: mix(0.2),
    fill: on.withValues(alpha: 0.2),
    secondaryFill: on.withValues(alpha: 0.16),
    tertiaryFill: on.withValues(alpha: 0.12),
    destructive: base.destructive,
    success: base.success,
    warning: base.warning,
  );
}

final Expando<Map<(int, int, int), ThemeData>> _blockThemes =
    Expando<Map<(int, int, int), ThemeData>>('fushiBlockThemes');

/// [base] 主题换成块配色 [colors] 后的局部主题（按 base 实例 + 三色缓存：首页
/// 一屏十几块，每块每帧重走主题工厂太贵）。
ThemeData fushiBlockTheme(ThemeData base, FushiCoverBlockColors colors) {
  final Map<(int, int, int), ThemeData> cache = _blockThemes[base] ??=
      <(int, int, int), ThemeData>{};
  return cache.putIfAbsent((
    colors.container.toARGB32(),
    colors.onContainer.toARGB32(),
    colors.accent.toARGB32(),
  ), () => _buildBlockTheme(base, colors));
}

ThemeData _buildBlockTheme(ThemeData base, FushiCoverBlockColors colors) {
  final ColorScheme scheme = fushiBlockColorScheme(base.colorScheme, colors);
  final FushiAppleColors? apple = base.extension<FushiAppleColors>();
  final TextTheme text = base.textTheme.apply(
    bodyColor: colors.onContainer,
    displayColor: colors.onContainer,
  );
  if (apple == null) {
    // MD3：重走主题工厂，组件主题里烤进去的颜色（开关滑块勾、菜单 / 对话框 /
    // 弹层底色……）全按块配色重算。
    final ThemeData rebuilt = rethemeFushiWithScheme(base, scheme);
    return rebuilt.copyWith(textTheme: text);
  }
  // Apple：工厂会把 scheme 再转成 Apple 系统灰（appleColorScheme），所以不重走
  // 工厂，直接换 scheme 与 Apple 色板（Apple 组件读的是色板）。ThemeData 按扩展
  // 类型建表、后者覆盖前者。
  final List<FushiAppleColors> blockApple = <FushiAppleColors>[
    fushiBlockAppleColors(apple, colors),
  ];
  return base.copyWith(
    colorScheme: scheme,
    canvasColor: colors.container,
    cardColor: scheme.surfaceContainerLow,
    dividerColor: scheme.outlineVariant,
    textTheme: text,
    iconTheme: base.iconTheme.copyWith(color: colors.onContainer),
    extensions: base.extensions.values.followedBy(blockApple),
  );
}

/// 给 [child] 子树下发块配色 [colors]（见文件头）。中性块原样返回 [child]。
class FushiBlockColorScope extends StatelessWidget {
  const FushiBlockColorScope({
    required this.colors,
    required this.child,
    super.key,
  });

  final FushiCoverBlockColors colors;
  final Widget child;

  /// [context] 所在色块的配色；不在带色块里时为 null。
  static FushiCoverBlockColors? maybeColorsOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_FushiBlockColorsMarker>()
      ?.colors;

  /// [context] 外最近一层带色块之外的原主题（中性主题）；不在带色块里时为 null。
  /// 见 [FushiNeutralColorScope]。
  static ThemeData? neutralThemeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_FushiBlockColorsMarker>()
      ?.neutral;

  @override
  Widget build(BuildContext context) {
    if (colors.hue == null) return child;
    final ThemeData theme = fushiBlockTheme(Theme.of(context), colors);
    // 嵌套 / 弹层里再包的块沿用最外层块之外的原主题，[FushiNeutralColorScope]
    // 据此一步退回中性主题。
    final ThemeData neutral =
        FushiBlockColorScope.neutralThemeOf(context) ?? Theme.of(context);
    return _FushiBlockColorsMarker(
      colors: colors,
      neutral: neutral,
      child: FushiPopupOriginScope(
        origin: FushiPopupOrigin(
          (Widget popup) => FushiBlockColorScope(colors: colors, child: popup),
        ),
        child: Theme(data: theme, child: child),
      ),
    );
  }
}

/// 块配色标记。是 [InheritedTheme]：弹层捕获主题时一并带走（弹层里的子块据此
/// 取同色相的深浅档，见 [FushiBlockColorScope.maybeColorsOf]）。
class _FushiBlockColorsMarker extends InheritedTheme {
  const _FushiBlockColorsMarker({
    required this.colors,
    required this.neutral,
    required super.child,
  });

  /// null = [FushiNeutralColorScope] 退回了中性主题（子树不再算在色块里）。
  final FushiCoverBlockColors? colors;

  /// 最外层带色块之外的原主题。
  final ThemeData neutral;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      _FushiBlockColorsMarker(colors: colors, neutral: neutral, child: child);

  @override
  bool updateShouldNotify(_FushiBlockColorsMarker oldWidget) =>
      !identical(neutral, oldWidget.neutral) ||
      colors?.container != oldWidget.colors?.container ||
      colors?.onContainer != oldWidget.colors?.onContainer ||
      colors?.accent != oldWidget.colors?.accent ||
      colors?.hue != oldWidget.colors?.hue;
}

/// 让子树退出带色块的局部配色、回到色块之外的原主题（中性主题）。不在带色块
/// 里时原样返回 [child]。
///
/// 用于设计系统本身要求中性配色的弹层：Apple（Cupertino）设计系统的导入对话框
/// 是 iOS 27 / macOS 27 的 inset grouped 表单（系统灰 + 强调色），从导入页色块
/// 弹出时不承接块配色（用户 2026-11-24：Cupertino 下不要暖色色块）。MD3 仍按
/// [FushiBlockColorScope] 的规则承接来源配色。
class FushiNeutralColorScope extends StatelessWidget {
  const FushiNeutralColorScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _FushiBlockColorsMarker? marker = context
        .dependOnInheritedWidgetOfExactType<_FushiBlockColorsMarker>();
    if (marker == null || marker.colors == null) return child;
    return _FushiBlockColorsMarker(
      colors: null,
      neutral: marker.neutral,
      child: FushiPopupOriginScope(
        // 子树里再弹出的东西同样是中性的（主题捕获已带走中性主题）。
        origin: FushiPopupOrigin((Widget popup) => popup),
        child: Theme(data: marker.neutral, child: child),
      ),
    );
  }
}
