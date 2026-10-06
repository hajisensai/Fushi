import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 页面级「中性装饰」：收编各页自画的 primaryContainer / secondaryContainer /
/// tertiaryContainer 彩色底块（图标方块、数字圆、提示块、小徽标）。
///
/// 为什么统一：彩色 tonal 底块是 MD2 → MD3 过渡期的观感，在同一屏里与填充胶囊
/// 按钮、中性分组卡并排时显得杂乱；Apple 26 更是只把强调色上在图标 / 文字 /
/// 主按钮上。规则（两套设计系统各自一份）：
/// - 装饰图标单色、无彩色底：MD3 = surfaceContainerHigh 中性圆底 +
///   onSurfaceVariant；Apple = 无底单色 label 图标（SF Symbols 不垫底块）。
/// - 信息块：MD3 = surfaceContainerHigh r12；Apple = `apple.tertiaryFill` r10。
/// - 语义（成功 / 警告 / 错误）只体现在单色图标或文字上。
/// - 墨水屏：中性灰底在 e-ink 上几乎不可见，统一补 1px outline 描边保住结构。

/// 页面自绘浮层（侧边面板、选区工具条、OSD 面板）的统一阴影档：MD3 elevation
/// level 2（3dp）。原先各处 6 / 8 的 MD2 式重投影收敛到这一档——层次主要靠
/// 表面色阶与圆角表达，阴影只做轻微分离。墨水屏主题本身 shadowColor 透明。
const double kFushiFloatingElevation = 3;

/// 信息块 / 提示块底色。
Color fushiNeutralBlockColor(BuildContext context) {
  if (isGlassDesign(context)) return appleColorsOf(context).tertiaryFill;
  return FushiDesignTokens.of(context).surfaces.search;
}

/// 信息块圆角：MD3 12、Apple 10（macOS / iOS 内嵌块的圆角）。
BorderRadius fushiNeutralBlockRadius(BuildContext context) =>
    BorderRadius.all(Radius.circular(isGlassDesign(context) ? 10 : 12));

/// 信息块完整装饰（底色 + 圆角；墨水屏补描边）。
BoxDecoration fushiNeutralBlockDecoration(BuildContext context) {
  return BoxDecoration(
    color: fushiNeutralBlockColor(context),
    borderRadius: fushiNeutralBlockRadius(context),
    border: isEinkTheme(context)
        ? Border.all(color: Theme.of(context).colorScheme.outline)
        : null,
  );
}

/// 信息块上的正文色（MD3 onSurface、Apple label）。
Color fushiNeutralBlockForeground(BuildContext context) {
  if (isGlassDesign(context)) return appleColorsOf(context).label;
  return Theme.of(context).colorScheme.onSurface;
}

/// 信息块上的次要文字 / 装饰图标色。
Color fushiNeutralSecondaryForeground(BuildContext context) {
  if (isGlassDesign(context)) return appleColorsOf(context).secondaryLabel;
  return Theme.of(context).colorScheme.onSurfaceVariant;
}

/// 「强调一处」的单色前景（MD3 primary、Apple accent）。
Color fushiAccentForeground(BuildContext context) {
  if (isGlassDesign(context)) return appleColorsOf(context).accent;
  return Theme.of(context).colorScheme.primary;
}

/// 小号 tonal 徽标（「新」「已下载」「n 卷」之类）的中性配色。
({Color background, Color foreground}) fushiNeutralTagColors(
  BuildContext context,
) {
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    // Apple 的元信息徽标是纯 secondaryLabel 文字，不铺 systemFill 灰底。
    return (background: Colors.transparent, foreground: apple.secondaryLabel);
  }
  final ColorScheme cs = Theme.of(context).colorScheme;
  return (
    background: FushiDesignTokens.of(context).surfaces.overlay,
    foreground: cs.onSurfaceVariant,
  );
}

/// 状态语义。
enum FushiStatusTone { success, warning, error }

/// 语义状态的单色前景（只给图标 / 文字用，不铺整块底）。
///
/// MD3 没有 success / warning 槽位：取 Material 绿 / 橙按主题主色做 HCT
/// harmonize（与 MD3「自定义颜色」同口径），深浅模式各取可读的那一档；
/// 墨水屏一律 onSurface（彩色在 e-ink 上只剩灰度，靠图标形状区分）。
Color fushiStatusColor(BuildContext context, FushiStatusTone tone) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  if (isEinkTheme(context)) return cs.onSurface;
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    return switch (tone) {
      FushiStatusTone.success => apple.success,
      FushiStatusTone.warning => apple.warning,
      FushiStatusTone.error => apple.destructive,
    };
  }
  final bool dark = cs.brightness == Brightness.dark;
  Color harmonized(int light, int darkArgb) => Color(
    Blend.harmonize(dark ? darkArgb : light, cs.primary.toARGB32()),
  );
  return switch (tone) {
    FushiStatusTone.success => harmonized(0xFF2E7D32, 0xFF81C995),
    FushiStatusTone.warning => harmonized(0xFFB26A00, 0xFFFFB95C),
    FushiStatusTone.error => cs.error,
  };
}

/// 中性底的装饰图标徽标（替代 primaryContainer 圆底 / 方块 + 彩色图标）。
class FushiNeutralIconBadge extends StatelessWidget {
  const FushiNeutralIconBadge({
    required this.icon,
    this.size = 40,
    this.iconSize,
    this.circle = true,
    this.color,
    super.key,
  });

  final IconData icon;

  /// 底的边长。
  final double size;

  /// 图标尺寸，缺省为 [size] 的一半。
  final double? iconSize;

  /// true 圆底，false 圆角方底（MD3 r12 / Apple r10）。
  final bool circle;

  /// 覆盖图标色（例如强调一处用 primary / accent）；缺省中性。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color background;
    final Color foreground;
    if (glass) {
      final FushiAppleColors apple = appleColorsOf(context);
      // 装饰图标不垫 systemFill 圆底（iOS / macOS 26 内容里的 SF Symbol
      // 直接单色上屏）；尺寸盒保留，布局不变。
      background = Colors.transparent;
      foreground = apple.label;
    } else {
      background = FushiDesignTokens.of(context).surfaces.search;
      foreground = cs.onSurfaceVariant;
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : fushiNeutralBlockRadius(context),
        border: isEinkTheme(context) ? Border.all(color: cs.outline) : null,
      ),
      child: FushiIcon(
        icon,
        size: iconSize ?? size / 2,
        color: color ?? foreground,
      ),
    );
  }
}

/// 步骤数字圆：当前步强调色实心，其余中性底。
class FushiStepNumberBadge extends StatelessWidget {
  const FushiStepNumberBadge({
    required this.number,
    this.active = false,
    this.size = 28,
    super.key,
  });

  final int number;

  /// 是否当前步（实心强调色）。
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Color background;
    final Color foreground;
    if (isGlassDesign(context)) {
      final FushiAppleColors apple = appleColorsOf(context);
      // 非当前步不铺灰底，只留一圈分隔线色细环（见下方 border）。
      background = active ? apple.accent : Colors.transparent;
      foreground = active ? apple.onAccent : apple.secondaryLabel;
    } else {
      background = active
          ? cs.primary
          : FushiDesignTokens.of(context).surfaces.search;
      foreground = active ? cs.onPrimary : cs.onSurface;
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: eink && !active
            ? Border.all(color: cs.outline)
            : (!active && isGlassDesign(context)
                ? Border.all(color: appleColorsOf(context).separator)
                : null),
      ),
      child: Text(
        '$number',
        style: theme.textTheme.labelLarge!.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
