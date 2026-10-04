import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 封面角标：压在封面图上的半透明黑胶囊（图标 / 文字，或两者）。
///
/// 统一书架/视频/游戏卡上「字幕/云端/播放列表/有声书」等角标的观感——此前
/// 同款胶囊在 home_video_page / remote.part 等处至少复制三份且 alpha 各异
/// （0.55~0.62）。封面上的角标底色**有意**固定深色而非跟随主题：它压在任意
/// 亮度的封面图上，跟随 colorScheme 反而在浅色主题下失去对比。
///
/// eink：半透明黑在墨水屏上合成抖动中间灰，改纯黑实底（前景仍是纯白）。
///
/// 角标统一（2026-10-04）：小圆角矩形（圆角 6）、内边距 4 / 6、10–11 号 w600 字。
/// - MD3：inverseSurface@0.85 底 + onInverseSurface 前景（浅色主题是深底、深色
///   主题是浅底，压在封面上都与周围拉得开）；
/// - Apple：HIG Materials 的「clear 玻璃压在媒体上」配方——背景模糊 + 35%
///   黑色调暗层 + 白字（不是一块近乎实心的黑底）。
/// 状态色（完成 / 失败 / 新）只落在 [iconColor] 上，不铺整块彩色底。
class CoverBadge extends StatelessWidget {
  const CoverBadge({
    this.icon,
    this.label,
    this.iconSize = 14,
    this.iconColor,
    super.key,
  }) : assert(
          icon != null || label != null,
          'CoverBadge needs an icon, a label, or both',
        );

  /// 角标图标（默认 14px）；null 时为纯文字角标
  /// （如合集详情「相关作品」卡上的关系类型徽标「前作 / 续作 / 剧场版」）。
  final IconData? icon;

  /// 可选文字（如播放列表集数「12」）；null 时为纯图标角标。
  final String? label;

  /// 图标尺寸，默认 14。
  final double iconSize;

  /// 图标颜色覆写：状态色（失败 / 部分完成等）只体现在图标上。null = 角标前景色。
  final Color? iconColor;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(6));

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    // Apple 角标自带磨砂，调暗层只要 HIG 的 35%；其余（墨水屏 / MD3）同 scrim。
    final Color background = apple && !eink
        ? Colors.black.withValues(alpha: 0.35)
        : coverBadgeScrim(context);
    final Color foreground = coverBadgeForeground(context);
    final Widget badge = Container(
      padding: label == null
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: background, borderRadius: _radius),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null)
            FushiIcon(icon, size: iconSize, color: iconColor ?? foreground),
          if (label != null) ...[
            if (icon != null) const SizedBox(width: 4),
            Text(
              label!,
              style: (Theme.of(context).textTheme.labelSmall ??
                      const TextStyle())
                  .copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.25,
                color: foreground,
              ),
            ),
          ],
        ],
      ),
    );
    if (!apple || eink) return badge;
    // Apple 磨砂：模糊只裁在角标自身的圆角里（BackdropFilter 不裁会糊满整屏）。
    return ClipRRect(
      borderRadius: _radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: badge,
      ),
    );
  }
}

/// 封面角标的底色：墨水屏纯黑、Apple 黑@0.55（无模糊的圆盘 / 圆钮也够对比）、MD3
/// inverseSurface@0.85。压在封面上的其它角标（下载进度圆盘等）也取这一份。
Color coverBadgeScrim(BuildContext context) {
  if (isEinkTheme(context)) return Colors.black;
  if (isGlassDesign(context)) return Colors.black.withValues(alpha: 0.55);
  return Theme.of(context).colorScheme.inverseSurface.withValues(alpha: 0.85);
}

/// 封面角标的前景色（文字 / 中性图标），与 [coverBadgeScrim] 配对。
Color coverBadgeForeground(BuildContext context) {
  if (isEinkTheme(context) || isGlassDesign(context)) return Colors.white;
  return Theme.of(context).colorScheme.onInverseSurface;
}

/// 封面角标上状态图标的颜色（完成 / 部分 / 失败）：MD3 取 container 色阶（在
/// inverseSurface 底上自动明暗反转、对比充足），Apple 取系统语义色。
Color coverBadgeStatusColor(
  BuildContext context, {
  bool error = false,
  bool warning = false,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    if (error) return apple.destructive;
    if (warning) return apple.warning;
    return Colors.white;
  }
  if (isEinkTheme(context)) return Colors.white;
  if (error) return cs.errorContainer;
  if (warning) return cs.tertiaryContainer;
  return cs.onInverseSurface;
}
