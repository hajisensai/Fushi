// M3 Expressive 轮播的共享件（用户 2026-10-05：发现页 hero 轮播等改为 M3E
// carousel）。
//
// - [FushiCarouselItemOffset]：轮播把「这一项离当前页多远」（-1 ~ 1，0 = 正中）
//   下发给项内部；
// - [FushiParallax]：项内的背景图按该偏移反向平移（M3E carousel 的 parallax：
//   图比遮罩移动得慢，翻页时像透过窗口看一张更大的图）；
// - [FushiCarouselItemTransform]：项本身的 M3E hero 形态——离开中心时收缩
//   并压暗少许，回到中心弹回原尺寸。
//
// 墨水屏 / 减弱动态效果下三者都原样返回 child（静止、无位移）。
import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 轮播项相对当前页的偏移（项序号 − 当前页）：0 = 正中；1 = 在末尾侧一整页
/// 之外；-1 = 起始侧。
class FushiCarouselItemOffset extends InheritedWidget {
  const FushiCarouselItemOffset({
    required this.offset,
    required super.child,
    super.key,
  });

  final double offset;

  /// 没有轮播祖先时为 null（同一组件单独使用，不做视差）。
  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiCarouselItemOffset>()
      ?.offset;

  @override
  bool updateShouldNotify(FushiCarouselItemOffset oldWidget) =>
      offset != oldWidget.offset;
}

/// 视差背景：读最近的 [FushiCarouselItemOffset]，把 [child] 放大 [overscan]
/// 后按偏移反向平移（最多移出放大余量，边缘永不露底）。
class FushiParallax extends StatelessWidget {
  const FushiParallax({required this.child, this.overscan = 1.18, super.key});

  final Widget child;

  /// 放大倍数（> 1），决定可平移的余量。
  final double overscan;

  @override
  Widget build(BuildContext context) {
    final double? offset = FushiCarouselItemOffset.maybeOf(context);
    if (offset == null || !fushiMotionEnabled(context)) return child;
    final double t = offset.clamp(-1.0, 1.0);
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return ClipRect(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double slack = constraints.maxWidth.isFinite
              ? constraints.maxWidth * (overscan - 1) / 2
              : 0;
          // offset = 项序号 − 当前页。项往起始侧滑走（offset → −1）时图相对
          // 遮罩往末尾侧退（比容器慢一拍），反之亦然；RTL 下翻页方向对调。
          final double dx = (rtl ? 1 : -1) * t * slack;
          return Transform.translate(
            offset: Offset(dx, 0),
            child: Transform.scale(scale: overscan, child: child),
          );
        },
      ),
    );
  }
}

/// M3E hero 轮播项的形态变化：离开中心时缩到 [minScale] 并略微压暗，
/// 回到中心恢复（随拖动连续变化，松手由 PageView 的吸附动画带回）。
class FushiCarouselItemTransform extends StatelessWidget {
  const FushiCarouselItemTransform({
    required this.child,
    this.minScale = 0.9,
    super.key,
  });

  final Widget child;
  final double minScale;

  @override
  Widget build(BuildContext context) {
    final double? offset = FushiCarouselItemOffset.maybeOf(context);
    if (offset == null || !fushiMotionEnabled(context)) return child;
    final double d = offset.abs().clamp(0.0, 1.0);
    final double scale = 1 - (1 - minScale) * d;
    return Transform.scale(
      scale: scale,
      child: Opacity(opacity: 1 - 0.25 * d, child: child),
    );
  }
}
