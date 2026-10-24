import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiBadgeControl;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 超过这个角度的项转到筒背面：不画、不可点。筒半径按它反推，让转到这个
/// 角度的项恰好落在胶囊边缘（见 [_DrumGeometry]）。
const double _kDrumHiddenDegrees = 80;

/// 正面相邻两项的投影间距（格宽 + 一点呼吸），筒面的角距由它和半径反推。
const double _kDrumFrontSpacing = 58;

/// 筒半径的上下限：太小透视失真，太大（超宽胶囊）筒面近乎平板、角距过小。
const double _kDrumMinRadius = 60;
const double _kDrumMaxRadius = 720;

/// 透视强度（`Matrix4` 第 3 行第 2 列），约等于 CSS `perspective: 555px`。
const double _kDrumPerspective = 0.0018;

/// 横拨多少逻辑像素转一格（约为正面间距 [_kDrumFrontSpacing] 的 0.7，
/// 与筒面铺满前的跟手比例一致）。
const double _kDrumPixelsPerStep = 42;

/// 松手速度（px/s）折算成多转几格的系数：约等于「再按当前速度滑 0.2 s」。
const double _kDrumFlingSeconds = 0.2;

/// 边缘橡皮筋最多越界多少格。
const double _kDrumRubberBand = 0.4;

/// 一项的边长（≥48dp 命中区），选中多边形与它同大。
const double _kDrumCellExtent = 52;

/// 吸附曲线：对齐原型 `cubic-bezier(.3, 1.2, .45, 1)`，末端轻微过冲。
const Cubic _kDrumSettleCurve = Cubic(0.3, 1.2, 0.45, 1);

/// 底栏原型「圆柱滚筒」（[AdaptiveNavBarStyle] 同名值，设计稿 F3）。
///
/// 全部目的地贴在一个横放圆柱的表面上，正面的项最大最清楚，两侧透视压扁、
/// 变淡并转到背面——透视本身就在说「还能转」。横拨只转动浏览、不切页，
/// 松手带惯性吸附到整数格；点图标才跳转（[NavOverflowSpec.onSelect]）并把它
/// 转到正面。墨水屏 / 减弱动态效果下降级为平面等距排列，不做透视与惯性。
///
/// 筒面铺满胶囊宽度：半径、角距按 [NavOverflowSpec.width] 推导（见
/// [_DrumGeometry]），平面降级同样按宽度均分。选中项背后是它专属的 M3E
/// 多边形（[navShapeOf]）。拖动（含松手惯性）每转过一格轻震一次。
class NavDrumBar extends StatefulWidget {
  const NavDrumBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavDrumBar> createState() => _NavDrumBarState();
}

class _NavDrumBarState extends State<NavDrumBar>
    with SingleTickerProviderStateMixin {
  /// 当前滚动位置（以 [NavOverflowSpec.indices] 的序号计，正面那一格）。
  late final AnimationController _pos;

  double _dragStart = 0;
  double _dragDx = 0;
  bool _dragging = false;

  /// 松手后的惯性吸附还在转（仍算用户在拨，经过的格照样震）。
  bool _flinging = false;

  /// 上次发触觉时正面那一格；用户拨动中它一变就轻震一次。
  int _hapticSlot = 0;

  NavOverflowSpec get _spec => widget.spec;

  int get _count => _spec.indices.length;

  /// 当前选中项在 [NavOverflowSpec.indices] 里的序号；当前页是 FAB 那一项
  /// 时为 -1（不画药丸）。
  int get _selectedSlot => _spec.indices.indexOf(_spec.currentIndex);

  @override
  void initState() {
    super.initState();
    final int slot = _selectedSlot;
    _pos = AnimationController.unbounded(
      vsync: this,
      value: slot < 0 ? 0 : slot.toDouble(),
    );
    _hapticSlot = _frontSlot(_pos.value);
    _pos.addListener(_onPosChanged);
    _pos.addStatusListener((AnimationStatus status) {
      if (!_pos.isAnimating) _flinging = false;
    });
  }

  /// 正面那一格（四舍五入，夹在合法范围内）。
  int _frontSlot(double pos) =>
      pos.round().clamp(0, math.max(0, _count - 1)).toInt();

  /// 正面那一格变了：用户拨动（拖动中或松手惯性）时轻震一次；点图标 / 外部
  /// 切页的吸附只同步不震（那一下 onSelect 已经震过）。
  void _onPosChanged() {
    final int slot = _frontSlot(_pos.value);
    if (slot == _hapticSlot) return;
    _hapticSlot = slot;
    if ((_dragging || _flinging) && mounted) fushiSelectionHaptic(context);
  }

  @override
  void didUpdateWidget(NavDrumBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int slot = _selectedSlot;
    if (oldWidget.spec.currentIndex != _spec.currentIndex &&
        slot >= 0 &&
        !_dragging) {
      // 外部切页（侧滑 / 快捷键 / FAB 回来）：把新的当前项转到正面。
      _flinging = false;
      _settleTo(slot.toDouble());
    } else if (!_dragging && !_pos.isAnimating) {
      final double clamped = _clampSlot(_pos.value);
      if (clamped != _pos.value) _pos.value = clamped;
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  double _maxSlot() => math.max(0, _count - 1).toDouble();

  double _clampSlot(double value) => value.clamp(0, _maxSlot()).toDouble();

  /// 拖动中的位置：界内跟手，越界部分按指数衰减收进 [_kDrumRubberBand] 内。
  double _rubberBand(double raw) {
    final double max = _maxSlot();
    double resist(double over) =>
        _kDrumRubberBand * (1 - math.exp(-over / (_kDrumRubberBand * 1.5)));
    if (raw < 0) return -resist(-raw);
    if (raw > max) return max + resist(raw - max);
    return raw;
  }

  void _settleTo(double target) {
    final double to = _clampSlot(target);
    final double distance = (to - _pos.value).abs();
    final Duration duration = fushiMotionDuration(
      context,
      Duration(milliseconds: (320 + 60 * distance).clamp(320, 700).round()),
    );
    if (duration == Duration.zero) {
      _pos.stop();
      _pos.value = to;
      _flinging = false;
      return;
    }
    _pos.animateTo(to, duration: duration, curve: _kDrumSettleCurve);
  }

  void _onDragStart(DragStartDetails details) {
    _pos.stop();
    _dragging = true;
    _dragStart = _pos.value;
    _dragDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragDx += details.primaryDelta ?? details.delta.dx;
    _pos.value = _rubberBand(_dragStart - _dragDx / _kDrumPixelsPerStep);
  }

  void _onDragEnd(DragEndDetails details) {
    _dragging = false;
    final bool motion = fushiMotionEnabled(context);
    final double velocity = motion ? (details.primaryVelocity ?? 0) : 0;
    final double fling = velocity / _kDrumPixelsPerStep * _kDrumFlingSeconds;
    _flinging = true;
    _settleTo((_pos.value - fling).roundToDouble());
  }

  void _onDragCancel() {
    _dragging = false;
    _flinging = true;
    _settleTo(_pos.value.roundToDouble());
  }

  void _onTapSlot(int slot) {
    _flinging = false;
    _settleTo(slot.toDouble());
    _spec.onSelect(_spec.indices[slot]);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool motion = fushiMotionEnabled(context);
    return ClipRect(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _onDragCancel,
        child: SizedBox(
          width: _spec.width,
          height: _spec.height,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (Rect bounds) => const LinearGradient(
                    colors: <Color>[
                      Color(0x00000000),
                      Color(0xFF000000),
                      Color(0xFF000000),
                      Color(0x00000000),
                    ],
                    stops: <double>[0, 0.22, 0.78, 1],
                  ).createShader(bounds),
                  child: AnimatedBuilder(
                    animation: _pos,
                    builder: (BuildContext context, Widget? _) =>
                        _buildCylinder(context, scheme, motion),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 2,
                child: Center(
                  child: IgnorePointer(
                    child: Container(
                      width: 16,
                      height: 3,
                      decoration: BoxDecoration(
                        color: scheme.onTertiaryContainer.withValues(
                          alpha: 0.35,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCylinder(BuildContext context, ColorScheme scheme, bool motion) {
    final double pos = _pos.value;
    final _DrumGeometry geometry = _DrumGeometry.forWidth(_spec.width);
    final int selected = _selectedSlot;
    final List<_DrumFace> faces = <_DrumFace>[];
    for (int slot = 0; slot < _count; slot++) {
      final _DrumFace? face = motion
          ? _cylinderFace(slot, pos, geometry)
          : _flatFace(slot, pos, geometry);
      if (face != null) faces.add(face);
    }
    // 远的先画，正面的最后画，避免背后的项盖住前面的。
    faces.sort((_DrumFace a, _DrumFace b) => b.depth.compareTo(a.depth));
    return Stack(
      children: <Widget>[
        for (final _DrumFace face in faces)
          Positioned.fill(
            key: ValueKey<int>(_spec.indices[face.slot]),
            child: Transform(
              alignment: Alignment.center,
              transform: face.transform,
              child: Opacity(
                opacity: face.opacity,
                child: Center(
                  child: _DrumCell(
                    item: _spec.item(_spec.indices[face.slot]),
                    shape: navShapeOf(_spec.items, _spec.indices[face.slot]),
                    selected: face.slot == selected,
                    scheme: scheme,
                    onTap: () => _onTapSlot(face.slot),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 3D 筒面：先把项推到筒轴（+R 远离观察者）、绕竖轴转、再拉回筒面。
  /// 整个变换以胶囊中心为透视原点（每层都铺满胶囊，图标居中）。
  _DrumFace? _cylinderFace(int slot, double pos, _DrumGeometry geometry) {
    final double radius = geometry.radius;
    final double degrees = (slot - pos) * geometry.stepDegrees;
    if (degrees.abs() > _kDrumHiddenDegrees) return null;
    final double radians = degrees * math.pi / 180;
    final Matrix4 transform = Matrix4.identity()
      ..setEntry(3, 2, _kDrumPerspective)
      ..translateByDouble(0, 0, radius, 1)
      ..rotateY(-radians)
      ..translateByDouble(0, 0, -radius, 1);
    final double cosine = math.cos(radians);
    return _DrumFace(
      slot: slot,
      depth: radius * (1 - cosine),
      opacity: math.max(0.15, cosine).clamp(0, 1).toDouble(),
      transform: transform,
    );
  }

  /// 平面降级：按宽度均分等距平铺，跟手平移、无透视；越出胶囊的不画。
  _DrumFace? _flatFace(int slot, double pos, _DrumGeometry geometry) {
    final double dx = (slot - pos) * geometry.flatSpacing;
    if (dx.abs() > _spec.width / 2 + _kDrumCellExtent / 2) return null;
    return _DrumFace(
      slot: slot,
      depth: dx.abs(),
      opacity: 1,
      transform: Matrix4.translationValues(dx, 0, 0),
    );
  }
}

/// 按胶囊宽度推导的筒面几何：让筒面铺满 [NavOverflowSpec.width]。
///
/// 筒面上角度 θ 的项（透视原点在胶囊中心，`w = 1 + p·R(1−cosθ)`）投影到
/// `x(θ) = R·sinθ / (1 + p·R(1−cosθ))`。令转到 [_kDrumHiddenDegrees] 的项
/// 恰好落在胶囊边缘内侧 X（半宽减去它被压扁后的残宽），解出
/// `R = X / (sinθmax − p·X·(1−cosθmax))`；角距取正面相邻两项投影间距
/// [_kDrumFrontSpacing]：`step = 2·asin(spacing / 2R)`。可见项数随宽度自然
/// 增减，而不是固定角距、固定半径让两侧空着。平面降级按宽度能放下的奇数个
/// 均分（当前项居中，两侧对称铺满）。
class _DrumGeometry {
  const _DrumGeometry({
    required this.radius,
    required this.stepDegrees,
    required this.flatSpacing,
  });

  factory _DrumGeometry.forWidth(double width) {
    const double hidden = _kDrumHiddenDegrees * math.pi / 180;
    final double sinMax = math.sin(hidden);
    final double versMax = 1 - math.cos(hidden);
    // 转到背面边缘的项被压扁到约 cellExtent·cosθmax 宽，让它的外沿贴着胶囊边。
    final double edge = math.max(
      0,
      width / 2 - _kDrumCellExtent * math.cos(hidden) / 2,
    );
    final double denominator = sinMax - _kDrumPerspective * edge * versMax;
    final double radius = denominator <= 0
        ? _kDrumMaxRadius
        : (edge / denominator).clamp(_kDrumMinRadius, _kDrumMaxRadius);
    final double half = (_kDrumFrontSpacing / 2 / radius).clamp(0.0, 1.0);
    final double step = (2 * math.asin(half) * 180 / math.pi).clamp(8.0, 40.0);
    // 平面：至少 1 个、奇数个，按宽度均分。
    int slots = (width / _kDrumCellExtent).floor();
    if (slots.isEven) slots -= 1;
    slots = math.max(1, slots);
    return _DrumGeometry(
      radius: radius,
      stepDegrees: step,
      flatSpacing: math.max(_kDrumCellExtent, width / slots),
    );
  }

  final double radius;
  final double stepDegrees;
  final double flatSpacing;
}

/// 筒面上一项的投影结果。
class _DrumFace {
  const _DrumFace({
    required this.slot,
    required this.depth,
    required this.opacity,
    required this.transform,
  });

  final int slot;

  /// 离观察者的远近（越大越远），用于排绘制顺序。
  final double depth;
  final double opacity;
  final Matrix4 transform;
}

/// 筒面上的一个图标格：纯图标，名字只进 Tooltip / Semantics；选中项背后
/// 画它专属的多边形（未选中是透明圆，切换时颜色与形状一起插值形变）。
class _DrumCell extends StatelessWidget {
  const _DrumCell({
    required this.item,
    required this.shape,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  final AdaptiveNavItem item;
  final RoundedPolygon shape;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(
      context,
      const Duration(milliseconds: 300),
    );
    final Color foreground = selected
        ? scheme.onTertiary
        : scheme.onTertiaryContainer;
    final Widget icon = FushiBadgeControl(
      isLabelVisible: item.experimentalBadge,
      child: FushiIcon(
        selected ? (item.selectedIcon ?? item.icon) : item.icon,
        color: foreground,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: FushiTooltip(
        message: item.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: fushiMd3StateCurve,
            width: _kDrumCellExtent,
            height: _kDrumCellExtent,
            alignment: Alignment.center,
            // AnimatedContainer 经 ShapeDecoration.lerp 走官方
            // MaterialShapeBorder 插值：圆 ↔ 专属多边形连续形变。
            decoration: ShapeDecoration(
              color: selected ? scheme.tertiary : scheme.tertiary.withAlpha(0),
              shape: MaterialShapeBorder(
                shape: selected ? shape : MaterialShapes.circle,
              ),
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}
