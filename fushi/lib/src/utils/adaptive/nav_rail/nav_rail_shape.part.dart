part of '../adaptive_navigation.dart';

/// MD3 侧栏的选中形状：没给 [AdaptiveNavItem.railShape] 的目的地按序号轮流取。
/// 全是 M3E 官方 [MaterialShapes]，彼此轮廓差得够开，相邻两项不会撞形。
final List<RoundedPolygon> kNavRailFallbackShapes = <RoundedPolygon>[
  MaterialShapes.cookie9Sided,
  MaterialShapes.clover4Leaf,
  MaterialShapes.softBurst,
  MaterialShapes.flower,
  MaterialShapes.puffy,
  MaterialShapes.sunny,
  MaterialShapes.gem,
  MaterialShapes.pentagon,
  MaterialShapes.cookie6Sided,
  MaterialShapes.clover8Leaf,
];

/// 收起 rail 的选中形状 / 墨滴落点边长（56 宽的格里居中，四周留 2）。
const double _kNavRailShapeSize = 52;

/// 展开 rail 行里图标背后的小形状边长。
const double _kNavRailRowShapeSize = 40;

/// MD3 侧栏选中项图标背后的专属形状（M3E shape morph）。
///
/// 一次切换的三段：旧项的形状在墨滴起飞那一帧收起（墨滴以同色圆形接手，
/// 见 [_SlidingIndicatorScope.liquid]）→ 墨滴流到新项落定 → 本组件从圆
/// 形变成 [shape]（官方 [MaterialShapeBorder] 插值，expressive 弹簧带回弹），
/// 之后缓慢自转。[visible] 为 false（未选中，或墨滴还在路上）时不画。
/// 墨水屏 / 减弱动态效果下直接画成最终形状、不转。
class _NavRailShape extends StatefulWidget {
  const _NavRailShape({
    required this.shape,
    required this.visible,
    required this.color,
    required this.size,
  });

  final RoundedPolygon shape;
  final bool visible;
  final Color color;
  final double size;

  @override
  State<_NavRailShape> createState() => _NavRailShapeState();
}

class _NavRailShapeState extends State<_NavRailShape>
    with TickerProviderStateMixin {
  late final FushiSpring _morph = FushiSpring(
    vsync: this,
    spring: _kNavExpressiveSpatial,
  );

  bool _motion = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = fushiExpressiveMotionEnabled(context);
    _sync(initial: true);
  }

  @override
  void didUpdateWidget(covariant _NavRailShape oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible ||
        oldWidget.shape != widget.shape) {
      _sync(initial: false);
    }
  }

  void _sync({required bool initial}) {
    if (!widget.visible) {
      _morph.animateTo(0, animate: false);
      return;
    }
    // 初次挂载就已选中（开 app / 展开收起换了一份格）：直接是最终形状，
    // 不在没有墨滴落地的时候凭空变形一次。
    _morph.animateTo(1, animate: _motion && !initial);
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return SizedBox.square(dimension: widget.size);
    final MaterialShapeBorder from = MaterialShapeBorder(
      shape: MaterialShapes.circle,
    );
    final MaterialShapeBorder to = MaterialShapeBorder(shape: widget.shape);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _morph.animation,
        builder: (BuildContext context, Widget? _) {
          // 弹簧过冲会让进度略超 1：形状插值只取 [0, 1]。
          final double t = _morph.value;
          final ShapeBorder border = OutlinedBorder.lerp(
            from,
            to,
            t.clamp(0.0, 1.0),
          )!;
          // 墨滴落定时就是同色同大的圆：形变从等大的圆开始，不缩一下；
          // 只把弹簧过冲换成一点点鼓起。
          final double scale = t <= 1 ? 1 : 1 + (t - 1) * 0.6;
          return Transform.scale(
            scale: scale,
            child: SizedBox.square(
              dimension: widget.size,
              child: DecoratedBox(
                decoration: ShapeDecoration(color: widget.color, shape: border),
              ),
            ),
          );
        },
      ),
    );
  }
}
