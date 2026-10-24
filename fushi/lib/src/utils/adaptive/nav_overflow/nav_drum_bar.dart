import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 相邻两项在筒面上相隔的角度（度）。
const double _kDrumStepDegrees = 24;

/// 超过这个角度的项转到筒背面：不画、不可点。
const double _kDrumHiddenDegrees = 80;

/// 透视强度（`Matrix4` 第 3 行第 2 列），约等于 CSS `perspective: 555px`。
const double _kDrumPerspective = 0.0018;

/// 横拨多少逻辑像素转一格。
const double _kDrumPixelsPerStep = 34;

/// 松手速度（px/s）折算成多转几格的系数：约等于「再按当前速度滑 0.2 s」。
const double _kDrumFlingSeconds = 0.2;

/// 边缘橡皮筋最多越界多少格。
const double _kDrumRubberBand = 0.4;

/// 一项的边长（≥48dp 命中区）与选中药丸圆角。
const double _kDrumCellExtent = 52;
const double _kDrumPillRadius = 18;

/// 平面降级（墨水屏 / 减弱动态效果）时的等距间隔。
const double _kDrumFlatSpacing = 52;

/// 吸附曲线：对齐原型 `cubic-bezier(.3, 1.2, .45, 1)`，末端轻微过冲。
const Cubic _kDrumSettleCurve = Cubic(0.3, 1.2, 0.45, 1);

/// 底栏原型「圆柱滚筒」（[AdaptiveNavBarStyle] 同名值，设计稿 F3）。
///
/// 全部目的地贴在一个横放圆柱的表面上，正面的项最大最清楚，两侧透视压扁、
/// 变淡并转到背面——透视本身就在说「还能转」。横拨只转动浏览、不切页，
/// 松手带惯性吸附到整数格；点图标才跳转（[NavOverflowSpec.onSelect]）并把它
/// 转到正面。墨水屏 / 减弱动态效果下降级为平面等距排列，不做透视与惯性。
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
  }

  @override
  void didUpdateWidget(NavDrumBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int slot = _selectedSlot;
    if (oldWidget.spec.currentIndex != _spec.currentIndex &&
        slot >= 0 &&
        !_dragging) {
      // 外部切页（侧滑 / 快捷键 / FAB 回来）：把新的当前项转到正面。
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
    _settleTo((_pos.value - fling).roundToDouble());
  }

  void _onDragCancel() {
    _dragging = false;
    _settleTo(_pos.value.roundToDouble());
  }

  void _onTapSlot(int slot) {
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
    final double radius = math.min(118, _spec.width / 2);
    final int selected = _selectedSlot;
    final List<_DrumFace> faces = <_DrumFace>[];
    for (int slot = 0; slot < _count; slot++) {
      final _DrumFace? face = motion
          ? _cylinderFace(slot, pos, radius)
          : _flatFace(slot, pos);
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
  _DrumFace? _cylinderFace(int slot, double pos, double radius) {
    final double degrees = (slot - pos) * _kDrumStepDegrees;
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

  /// 平面降级：等距平铺，跟手平移、无透视；越出胶囊的不画。
  _DrumFace? _flatFace(int slot, double pos) {
    final double dx = (slot - pos) * _kDrumFlatSpacing;
    if (dx.abs() > _spec.width / 2 + _kDrumCellExtent / 2) return null;
    return _DrumFace(
      slot: slot,
      depth: dx.abs(),
      opacity: 1,
      transform: Matrix4.translationValues(dx, 0, 0),
    );
  }
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

/// 筒面上的一个图标格：纯图标，名字只进 Tooltip / Semantics；选中画药丸。
class _DrumCell extends StatelessWidget {
  const _DrumCell({
    required this.item,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  final AdaptiveNavItem item;
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
    final Widget icon = Badge(
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
      child: Tooltip(
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
            decoration: BoxDecoration(
              color: selected ? scheme.tertiary : scheme.tertiary.withAlpha(0),
              borderRadius: BorderRadius.circular(
                selected ? _kDrumPillRadius : _kDrumCellExtent / 2,
              ),
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}
