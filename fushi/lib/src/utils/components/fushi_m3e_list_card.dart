import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;

// 列表与卡片的 Material 3 Expressive 共享规格（2026-10-05「列表和卡片也统一成
// m3e」）。这里只放**规格与小原语**：形状分级、状态形变、卡片配色变体、列表行首
// 形状底、滑动操作底；真正的卡片 / 行组件仍是 FushiCard / FushiListItem /
// FushiGroupedListItem（fushi_material_components.dart / fushi_glass_lists.dart），
// 它们从这里取值。Apple 设计系统用同一套 API，落到 iOS inset grouped / 彩色
// 圆角方块图标 / 系统色滑动操作上。
//
// 规格来源：m3.material.io Lists / Cards（Expressive 更新）——
// - 分段列表（segmented list）：每行一张面，行间 2dp，组首尾外侧大圆角、内侧
//   小圆角；行在悬停时内侧角形变到 12、按下 / 聚焦 / 选中时形变到 16，选中底
//   secondaryContainer。
// - 卡片：elevated / filled / outlined 三类；本仓圆角分级 大容器 28 / 卡 20 /
//   小件 12（用户 2026-10-05 定调），卡片可用饱和 container 色块分区。

/// M3E 形状分级（圆角半径，逻辑像素）。卡片 / 容器 / 小件按层级取值，不再
/// 各处手写 8 / 10 / 14 / 16。
abstract final class FushiM3eShape {
  /// 大容器：面板、侧板、整块分区（与对话框 / 底部弹层同档）。
  static const double containerLarge = 28;

  /// 卡片（FushiCard / FushiCardControl 默认）。
  static const double card = 20;

  /// 小件：卡内的小块、缩略图、标签底、行首方形图标底。
  static const double small = 12;

  /// 列表行悬停时的形变目标（M3E corner-medium）。
  static const double listHover = 12;

  /// 列表行按下 / 聚焦 / 选中时的形变目标（M3E corner-large）。
  static const double listActive = 16;

  static const BorderRadius containerLargeRadius = BorderRadius.all(
    Radius.circular(containerLarge),
  );
  static const BorderRadius cardRadius = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius smallRadius = BorderRadius.all(
    Radius.circular(small),
  );
}

/// 列表行 / 分段卡的交互形变：把 [base] 的每个角抬到不小于目标值。
///
/// [level] 是连续值（弹簧驱动）：0 = 静止（原样）、1 = 悬停（≥ 12）、
/// 2 = 按下 / 聚焦 / 选中（≥ 16）。外侧本就更大的角（分段组首尾 24）不变，
/// 只有内侧小角被「撑圆」——这就是 M3E 分段列表的选中形变。
BorderRadius fushiM3eMorphRadius(BorderRadius base, double level) {
  if (level <= 0) return base;
  final double target = level <= 1
      ? FushiM3eShape.listHover * level
      : FushiM3eShape.listHover +
            (FushiM3eShape.listActive - FushiM3eShape.listHover) *
                math.min(level - 1, 1.0);
  Radius lift(Radius r) {
    // 只在静止角小于目标时向目标插值（level 0→1 从原角渐变到 12）。
    final double from = r.x;
    if (from >= FushiM3eShape.listActive) return r;
    final double to = math.max(from, target);
    return Radius.circular(to);
  }

  return BorderRadius.only(
    topLeft: lift(base.topLeft),
    topRight: lift(base.topRight),
    bottomLeft: lift(base.bottomLeft),
    bottomRight: lift(base.bottomRight),
  );
}

/// 卡片的三类容器（M3 cards）。
enum FushiCardVariant {
  /// 填充卡（默认）：surfaceContainerLow 分层，无描边无阴影。
  filled,

  /// 抬升卡：surfaceContainerLow + level1 投影，悬停升到 level2。
  elevated,

  /// 描边卡：surface 底 + outlineVariant 1px。
  outlined,
}

/// 卡片的 M3E 饱和配色变体：用强调色大色块给内容分区（进度卡、当前章、
/// 推荐位），而不是淡描边。neutral = 中性分层（默认）。
enum FushiCardTone { neutral, primary, secondary, tertiary, error }

/// 一张卡的底色与前景色。
@immutable
class FushiCardColors {
  const FushiCardColors({required this.container, required this.onContainer});

  final Color container;

  /// null 语义 = 继承（中性卡不改前景）。
  final Color? onContainer;
}

/// [tone] 在当前设计系统下的底色 / 前景。neutral 返回 null（交给卡片按变体
/// 取中性分层色）。
///
/// - MD3（M3E）：xxxContainer / onXxxContainer 饱和色块；
/// - Apple：强调色 / 系统色的 15% 淡染底 + 原色前景（iOS 卡片不用大面积饱和
///   实色，同一语义落到淡染上）；
/// - 墨水屏：容器色塌缩成背景，不上色（返回 null，卡片走描边口径）。
FushiCardColors? fushiCardToneColors(BuildContext context, FushiCardTone tone) {
  if (tone == FushiCardTone.neutral || isEinkTheme(context)) return null;
  final ColorScheme cs = Theme.of(context).colorScheme;
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    final Color base = switch (tone) {
      FushiCardTone.primary => apple.accent,
      FushiCardTone.secondary => apple.accent,
      FushiCardTone.tertiary => apple.success,
      FushiCardTone.error => apple.destructive,
      FushiCardTone.neutral => apple.accent,
    };
    return FushiCardColors(
      container: tone == FushiCardTone.secondary
          ? apple.secondaryFill
          : base.withValues(alpha: 0.15),
      onContainer: tone == FushiCardTone.secondary ? apple.label : base,
    );
  }
  return switch (tone) {
    FushiCardTone.primary => FushiCardColors(
      container: cs.primaryContainer,
      onContainer: cs.onPrimaryContainer,
    ),
    FushiCardTone.secondary => FushiCardColors(
      container: cs.secondaryContainer,
      onContainer: cs.onSecondaryContainer,
    ),
    FushiCardTone.tertiary => FushiCardColors(
      container: cs.tertiaryContainer,
      onContainer: cs.onTertiaryContainer,
    ),
    FushiCardTone.error => FushiCardColors(
      container: cs.errorContainer,
      onContainer: cs.onErrorContainer,
    ),
    FushiCardTone.neutral => FushiCardColors(
      container: cs.surfaceContainerLow,
      onContainer: null,
    ),
  };
}

/// M3 elevation level1 / level2 的投影（Material 3 key + ambient 两层）。
/// [t] 在 0（level1）与 1（level2）之间插值，悬停抬升时连续变化。
List<BoxShadow> fushiM3eCardShadow(BuildContext context, double t) {
  final Color shadow = Theme.of(context).colorScheme.shadow;
  final double k = t.clamp(0.0, 1.0);
  return <BoxShadow>[
    BoxShadow(
      color: shadow.withValues(alpha: 0.30),
      offset: Offset(0, 1 + k),
      blurRadius: 2 + 2 * k,
    ),
    BoxShadow(
      color: shadow.withValues(alpha: 0.15),
      offset: Offset(0, 1 + 1 * k),
      blurRadius: 3 + 3 * k,
      spreadRadius: 1 + k,
    ),
  ];
}

/// 列表行首图标底的形状（M3E 形状库里列表常用的几种）。
enum FushiLeadingShape {
  /// 圆（默认）。
  circle,

  /// 圆角方块（小件 12）。
  square,

  /// 四瓣「cookie」——M3E 形状库的 4-sided cookie，用于强调 / 当前项。
  cookie,

  /// 九瓣「花瓣」——M3E 形状库的 9-sided cookie，用于高亮 / 推荐项。
  flower,
}

/// 列表行首的 M3E 形状图标底：40×40 的 secondaryContainer 形状里放一个 24 的
/// onSecondaryContainer 图标（[tone] 可换成 primary / tertiary 饱和色块）。
///
/// Apple 设计系统下是 iOS「设置」式彩色圆角方块（[FushiAppleMetrics.iconTileSize]
/// 边长、强调色 / 系统色实底、白色图标），形状参数不影响 Apple 外观。
/// 墨水屏下退成无底单色图标 + 1px 描边。
class FushiListLeadingIcon extends StatelessWidget {
  const FushiListLeadingIcon(
    this.icon, {
    super.key,
    this.shape = FushiLeadingShape.circle,
    this.tone = FushiCardTone.secondary,
    this.size = 40,
    this.iconSize,
  });

  final IconData icon;
  final FushiLeadingShape shape;
  final FushiCardTone tone;

  /// 形状底边长（MD3）。
  final double size;

  /// 图标尺寸；null = MD3 24 / Apple 按方块比例。
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (isGlassDesign(context)) {
      final FushiAppleColors apple = appleColorsOf(context);
      final double tile = FushiAppleMetrics.of(context).iconTileSize;
      final Color bg = switch (tone) {
        FushiCardTone.tertiary => apple.success,
        FushiCardTone.error => apple.destructive,
        FushiCardTone.neutral => apple.secondaryLabel,
        _ => apple.accent,
      };
      return SizedBox.square(
        dimension: tile,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: bg,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(tile * 0.26),
            ),
          ),
          child: FushiIcon(
            icon,
            size: iconSize ?? tile * 0.64,
            color: tone == FushiCardTone.error || tone == FushiCardTone.tertiary
                ? Colors.white
                : apple.onAccent,
          ),
        ),
      );
    }
    final bool eink = isEinkTheme(context);
    final FushiCardColors colors =
        fushiCardToneColors(context, tone) ??
        FushiCardColors(
          container: eink ? cs.surface : cs.surfaceContainerHighest,
          onContainer: cs.onSurfaceVariant,
        );
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: eink ? cs.surface : colors.container,
          shape: fushiLeadingShapeBorder(
            shape,
            side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
          ),
        ),
        child: FushiIcon(
          icon,
          size: iconSize ?? 24,
          color: eink ? cs.onSurface : colors.onContainer,
        ),
      ),
    );
  }
}

/// [shape] 对应的 [ShapeBorder]。
ShapeBorder fushiLeadingShapeBorder(
  FushiLeadingShape shape, {
  BorderSide side = BorderSide.none,
}) {
  return switch (shape) {
    FushiLeadingShape.circle => CircleBorder(side: side),
    FushiLeadingShape.square => RoundedRectangleBorder(
      borderRadius: FushiM3eShape.smallRadius,
      side: side,
    ),
    FushiLeadingShape.cookie => FushiCookieBorder(lobes: 4, side: side),
    FushiLeadingShape.flower => FushiCookieBorder(lobes: 9, side: side),
  };
}

/// M3E 形状库的「cookie」族：圆周上 [lobes] 个圆润凸瓣（4 = 四瓣 cookie，
/// 9 = 花瓣）。半径 r(θ) = R·(1 − depth·(1 − cos(lobes·θ))/2)，瓣深 [depth]
/// 取 M3E 形状的观感值。
class FushiCookieBorder extends OutlinedBorder {
  const FushiCookieBorder({required this.lobes, this.depth = 0.14, super.side});

  final int lobes;
  final double depth;

  Path _path(Rect rect) {
    final Offset c = rect.center;
    final double r = rect.shortestSide / 2;
    const int steps = 144;
    final Path path = Path();
    for (int i = 0; i <= steps; i++) {
      final double theta = 2 * math.pi * i / steps - math.pi / 2;
      final double k = 1 - depth * (1 - math.cos(lobes * theta)) / 2;
      final Offset p = c + Offset(math.cos(theta), math.sin(theta)) * (r * k);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawPath(_path(rect.deflate(side.strokeInset / 2)), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) =>
      FushiCookieBorder(lobes: lobes, depth: depth, side: side.scale(t));

  @override
  FushiCookieBorder copyWith({BorderSide? side}) =>
      FushiCookieBorder(lobes: lobes, depth: depth, side: side ?? this.side);

  @override
  bool operator ==(Object other) =>
      other is FushiCookieBorder &&
      other.lobes == lobes &&
      other.depth == depth &&
      other.side == side;

  @override
  int get hashCode => Object.hash(lobes, depth, side);
}

/// 滑动操作（[Dismissible] 的 background / secondaryBackground）的统一底：
/// 与行同形的圆角色块 + 图标 + 可选文字，贴在滑出的那一侧。
///
/// - MD3（M3E）：destructive = errorContainer / onErrorContainer，其余
///   tertiaryContainer / onTertiaryContainer；圆角默认卡片 20；
/// - Apple：系统红（destructive）/ 强调色实底 + 白色图标文字，iOS 行内滑动
///   操作口径；
/// - 墨水屏：页面底 + 实描边。
class FushiSwipeActionBackground extends StatelessWidget {
  const FushiSwipeActionBackground({
    required this.icon,
    super.key,
    this.label,
    this.destructive = false,
    this.alignment = AlignmentDirectional.centerEnd,
    this.borderRadius,
  });

  final IconData icon;
  final String? label;
  final bool destructive;

  /// 内容贴哪一侧（向左滑删除 = centerEnd）。
  final AlignmentGeometry alignment;

  /// null = MD3 卡片 20 / Apple 分组圆角。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color bg;
    final Color fg;
    BorderRadius radius = borderRadius ?? FushiM3eShape.cardRadius;
    if (isGlassDesign(context)) {
      final FushiAppleColors apple = appleColorsOf(context);
      bg = destructive ? apple.destructive : apple.accent;
      fg = destructive ? Colors.white : apple.onAccent;
      radius = borderRadius ?? FushiAppleMetrics.of(context).groupBorderRadius;
    } else if (eink) {
      bg = cs.surface;
      fg = cs.onSurface;
    } else {
      bg = destructive ? cs.errorContainer : cs.tertiaryContainer;
      fg = destructive ? cs.onErrorContainer : cs.onTertiaryContainer;
    }
    final String? text = label;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: eink ? Border.all(color: cs.outline) : null,
      ),
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(icon, color: fg),
              if (text != null && text.isNotEmpty) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  text,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: fg),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
