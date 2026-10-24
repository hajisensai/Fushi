import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiSpring, fushiExpressiveMotionEnabled;

/// M3 Expressive「expressive」动效方案的 default spatial 弹簧（刚度 380、
/// 阻尼比 0.8）：导航指示器选中时带一点回弹地展开、选中形状由圆变形，侧栏与
/// 底栏（含各底栏原型）同用。
final SpringDescription kNavExpressiveSpatial =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8);

/// MD3 导航的选中形状：没给 [AdaptiveNavItem.railShape] 的目的地按序号轮流取。
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

/// [items] 里第 [index] 个目的地的选中形状（侧栏、底栏、底栏原型同一套）。
RoundedPolygon navShapeOf(List<AdaptiveNavItem> items, int index) =>
    items[index].railShape ??
    kNavRailFallbackShapes[index % kNavRailFallbackShapes.length];

/// MD3 导航选中项图标背后的专属形状（M3E shape morph），侧栏与底栏共用。
///
/// 一次切换的三段：旧项的形状在墨滴起飞那一帧收起（墨滴以同色圆形接手，
/// 见 adaptive_navigation 的 `_SlidingIndicatorScope.liquid`）→ 墨滴流到新项
/// 落定 → 本组件从圆形变成 [shape]（官方 [MaterialShapeBorder] 插值，
/// expressive 弹簧带回弹）。[visible] 为 false（未选中，或墨滴还在路上）时
/// 不画。墨水屏 / 减弱动态效果下直接画成最终形状。
class NavMorphShape extends StatefulWidget {
  const NavMorphShape({
    super.key,
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
  State<NavMorphShape> createState() => _NavMorphShapeState();
}

class _NavMorphShapeState extends State<NavMorphShape>
    with TickerProviderStateMixin {
  late final FushiSpring _morph = FushiSpring(
    vsync: this,
    spring: kNavExpressiveSpatial,
  );

  bool _motion = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = fushiExpressiveMotionEnabled(context);
    _sync(initial: true);
  }

  @override
  void didUpdateWidget(covariant NavMorphShape oldWidget) {
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
