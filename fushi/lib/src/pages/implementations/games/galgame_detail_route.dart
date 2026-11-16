import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 首页首块封面 → 详情封面的共享元素 tag（设计稿 GA24：「详情」放大时封面从
/// -7° 转到 0°）。只有从首块发起的放大才给详情页传这个 tag（见
/// `GalgameDetailPage.coverHeroTag`）：游戏库等别处打开详情不带 tag，不会和首页
/// 常驻（IndexedStack 里藏着也算）的首块封面配对飞行。
String galgameCoverHeroTag(String gameId) => 'galgame-cover-$gameId';

/// 首块封面静止斜放的角度（度，LTR；RTL 镜像）。与 `_TiltedArt` 的静止姿态同值。
const double kGalgameCoverRestDegrees = -7;

/// 封面共享元素的飞行替身：画详情一侧的封面，角度随路由动画从首块的
/// [kGalgameCoverRestDegrees] 插值到 0°（返回时反向）。[animation] 是路由动画
/// （push 0 → 1、pop 1 → 0），所以同一个式子两个方向都对。
Widget galgameCoverFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final Hero detailHero =
      (direction == HeroFlightDirection.push
              ? toHeroContext.widget
              : fromHeroContext.widget)
          as Hero;
  final double dir = Directionality.of(flightContext) == TextDirection.rtl
      ? -1
      : 1;
  return AnimatedBuilder(
    animation: animation,
    child: detailHero.child,
    builder: (BuildContext context, Widget? child) => Transform.rotate(
      angle:
          dir *
          kGalgameCoverRestDegrees *
          (1 - animation.value) *
          math.pi /
          180,
      child: child,
    ),
  );
}

/// 游戏详情「从原位放大」的推入路由（设计稿 GA24「详情」入口 → 容器变换）。
///
/// [originContext] 是被点的块（首块 / 继续块 / 随机推荐块）：取它在 Navigator
/// 覆盖层里的矩形，详情页先以块的容器色 [containerColor] 铺满该矩形，再在
/// 弹簧插值里把矩形放大到全屏、圆角收成 0，内容在后半程淡入；返回时反向播放。
/// 减弱动效（[fushiMotionEnabled] 为 false，含墨水屏）改成淡入淡出
/// （fade-through），不做位移与缩放。时长 / 曲线只取 [FushiMotionScheme]。
///
/// 块还没布局（拿不到矩形）时退回同一条淡入淡出，不猜一个起点。
Future<T?> pushGalgameDetailFromOrigin<T>({
  required BuildContext context,
  required BuildContext originContext,
  required Color containerColor,
  required double originRadius,
  required WidgetBuilder builder,
}) {
  final NavigatorState navigator = Navigator.of(context);
  final Rect? origin = _originRectIn(navigator, originContext);
  final FushiMotionScheme motion = FushiMotionScheme.of(context);
  final bool spatial = fushiMotionEnabled(context) && origin != null;
  return navigator.push<T>(
    PageRouteBuilder<T>(
      transitionDuration: motion.spatialSlow.duration,
      reverseTransitionDuration: motion.spatialDefault.duration,
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) => builder(context),
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) {
            if (!spatial) {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: motion.effectsDefault.curve,
                ),
                child: child,
              );
            }
            return GalgameDetailContainerTransform(
              animation: CurvedAnimation(
                parent: animation,
                curve: motion.spatialSlow.curve,
                reverseCurve: motion.spatialDefault.curve,
              ),
              origin: origin,
              originRadius: originRadius,
              containerColor: containerColor,
              child: child,
            );
          },
    ),
  );
}

/// [originContext] 的渲染盒在 [navigator] 覆盖层坐标里的矩形；未布局为 null。
Rect? _originRectIn(NavigatorState navigator, BuildContext originContext) {
  final RenderObject? box = originContext.findRenderObject();
  final RenderObject? overlay = navigator.overlay?.context.findRenderObject();
  if (box is! RenderBox ||
      !box.hasSize ||
      !box.attached ||
      overlay is! RenderBox) {
    return null;
  }
  final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
  return topLeft & box.size;
}

/// 容器变换本体：[animation] 0 → 1 时裁剪矩形由 [origin] 插值到整个视口、圆角由
/// [originRadius] 收到 0；底下先垫块的容器色，详情内容在后 70% 淡入（前 30%
/// 只看到色块在长大，内容不会被压成一条缝）。内容按全屏布局、只被裁剪，不缩放。
class GalgameDetailContainerTransform extends StatelessWidget {
  const GalgameDetailContainerTransform({
    required this.animation,
    required this.origin,
    required this.originRadius,
    required this.containerColor,
    required this.child,
    super.key,
  });

  final Animation<double> animation;
  final Rect origin;
  final double originRadius;
  final Color containerColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Rect target = Offset.zero & constraints.biggest;
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (BuildContext context, Widget? child) {
            final double t = animation.value;
            final Rect rect = Rect.lerp(origin, target, t)!;
            final double radius = math.max(0, originRadius * (1 - t));
            final double contentOpacity = ((t - 0.3) / 0.7).clamp(0.0, 1.0);
            return ClipPath(
              clipper: _RectClipper(rect: rect, radius: radius),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(color: containerColor),
                  Opacity(opacity: contentOpacity, child: child),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _RectClipper extends CustomClipper<Path> {
  const _RectClipper({required this.rect, required this.radius});

  final Rect rect;
  final double radius;

  @override
  Path getClip(Size size) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

  @override
  bool shouldReclip(_RectClipper oldClipper) =>
      oldClipper.rect != rect || oldClipper.radius != radius;
}
