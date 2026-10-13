import 'package:cupertino_ui/cupertino_ui.dart'
    show
        CupertinoPageTransition,
        CupertinoPageTransitionsBuilder,
        CupertinoRouteTransitionMixin;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// Apple（Cupertino）设计系统的页面转场：动效开启时就是原生
/// [CupertinoPageTransitionsBuilder]（右侧推入、旧页视差左移 + 压暗、边缘侧滑
/// 返回跟手）；系统「减弱动态效果」（[fushiMotionEnabled] 为 false）时退化成
/// **原地线性淡入**——不位移、无视差、不压暗，与 [FushiSharedAxisTransition] 的
/// 减弱动态效果档同口径。
///
/// 两条纪律：
/// - **返回手势不丢**：减弱动态效果下仍委托
///   [CupertinoRouteTransitionMixin.buildPageTransitions]（它装
///   `_CupertinoBackGestureDetector`），只是在没有拖动进行中时喂它已落定的动画
///   （同 `EinkCupertinoPageTransitionsBuilder`）；真在拖时照常跟手。iOS 没有系统
///   返回键，零转场 `return child` 会把侧滑返回从整个 app 拆掉。
/// - **子树结构恒定**：淡入层 [FadeTransition] 恒在，只换它的 opacity 源。系统
///   设置在页面打开期间切换时，页面子树不因增删包装层而重挂（丢 State）。
///
/// 继承 [CupertinoPageTransitionsBuilder]：时长、`isA` 判型与平台预期都与原生一致。
/// 墨水屏不走这里（主题整套换成墨水屏 builder）。
class FushiCupertinoPageTransitionsBuilder
    extends CupertinoPageTransitionsBuilder {
  const FushiCupertinoPageTransitionsBuilder();

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _delegatedTransition;

  /// 被新页盖住的那一页（新页来自别的转场类型时）：减弱动态效果下不做视差。
  static Widget? _delegatedTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (!fushiMotionEnabled(context)) return child;
    return CupertinoPageTransition.delegatedTransition(
      context,
      animation,
      secondaryAnimation,
      allowSnapshotting,
      child,
    );
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 真在侧滑时一律跟手（减弱动态效果也不例外：手指拖动不是「自动播放的动画」）。
    final bool settled =
        !fushiMotionEnabled(context) && !route.popGestureInProgress;
    return FadeTransition(
      opacity: settled ? animation : kAlwaysCompleteAnimation,
      child: CupertinoRouteTransitionMixin.buildPageTransitions<T>(
        route,
        context,
        settled ? kAlwaysCompleteAnimation : animation,
        settled ? kAlwaysDismissedAnimation : secondaryAnimation,
        child,
      ),
    );
  }
}

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
/// 时长与曲线全部来自 M3E 弹簧 token（2026-10-05）：进入 = spatial slow 的落定
/// 时长 [FushiMotion.long]，退出 = effects slow [FushiMotion.longReverse]。
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
  // 位移是 spatial：M3E 整屏级 spatial slow 弹簧形状（[FushiMotion.long] 即其
  // 落定时长），落点带极轻回弹；淡入 / 压暗是 effects，临界阻尼不过冲。
  static final Animatable<double> _riseIn = CurveTween(
    curve: FushiSpringCurve.spatial,
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
