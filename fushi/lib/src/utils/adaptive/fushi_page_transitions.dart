import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 桌面（Windows / Linux / Fuchsia）页面转场：**新页上滑淡入，旧页原地不动**。
///
/// 取代此前的 [ZoomPageTransitionsBuilder]。Zoom 转场为「手机上从卡片放大成整页」
/// 设计：新页从 85% 放大、旧页同时放大到 105% 并淡出，在 1080p+ 的大窗口里是
/// 整窗缩放，位移量随窗口尺寸线性增长——4K 全屏下一次 push 等于把几百像素的
/// 画面整体推拉一遍，视觉上很「重」，而且两页同时缩放需要两层离屏合成。
///
/// 这里改成只与**固定像素距离**相关的轻量动作，与窗口大小无关：
/// - 进入页：从下方 [FushiMotion.enterOffset] × 1.5（24px）处上移到位，透明度在
///   动画前 20% 保持 0、随后淡入（先让旧页「让路」再出现，读起来是一次干净的
///   切换而不是两页叠影）。
/// - 被覆盖页：**不位移**，只原地压暗到 [_kScrimOpacity]，提示层级「新页在上面」。
///   早先版本让它同时上移 6px，用户实测反馈「进入页面时整个页面会往上一点」，
///   已去掉——底下那页必须纹丝不动。
/// - 返回（pop）走同一路径的反向，时长取 [FushiMotion.longReverse]，退出更快。
///
/// 系统「减弱动态效果」/ 墨水屏（[fushiMotionEnabled]）下退化成线性淡入、不位移、
/// 不压暗。
/// 墨水屏的主题本就整套换成 `EinkNoPageTransitionsBuilder`，这里只是兜底。
class FushiSharedAxisPageTransitionsBuilder extends PageTransitionsBuilder {
  const FushiSharedAxisPageTransitionsBuilder();

  @override
  Duration get transitionDuration => FushiMotion.long;

  @override
  Duration get reverseTransitionDuration => FushiMotion.longReverse;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FushiSharedAxisTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

/// 被覆盖页压暗的上限（叠在页面上的 scrim 不透明度）。
const double _kScrimOpacity = 0.06;

/// [FushiSharedAxisPageTransitionsBuilder] 的转场本体，单独暴露给效果图脚本与
/// 测试直接驱动。
class FushiSharedAxisTransition extends StatelessWidget {
  const FushiSharedAxisTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
    super.key,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  static final Animatable<double> _fadeIn = CurveTween(
    curve: const Interval(0.2, 1, curve: FushiMotion.enter),
  );
  static final Animatable<double> _riseIn = CurveTween(
    curve: FushiMotion.enter,
  );
  static final Animatable<double> _coverOut = CurveTween(
    curve: FushiMotion.standard,
  );

  @override
  Widget build(BuildContext context) {
    final bool motion = fushiMotionEnabled(context);
    const double distance = FushiMotion.enterOffset * 1.5;
    final Color scrim = Theme.of(context).colorScheme.scrim;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[animation, secondaryAnimation]),
      child: child,
      builder: (BuildContext context, Widget? child) {
        final double enter = animation.value;
        final double cover = motion
            ? _coverOut.transform(secondaryAnimation.value)
            : 0;
        final double rise = motion ? _riseIn.transform(enter) : 1;
        return Opacity(
          opacity: motion ? _fadeIn.transform(enter) : enter,
          child: Transform.translate(
            // 只有进入页自己上滑；secondaryAnimation（被新页盖住）不参与位移。
            offset: Offset(0, (1 - rise) * distance),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                color: scrim.withValues(alpha: cover * _kScrimOpacity),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
