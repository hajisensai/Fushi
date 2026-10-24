import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 底栏原型「相机模式条」（[AdaptiveNavBarStyle] 同名值，设计稿 F5）。
///
/// 借相机 App「照片 / 视频 / 人像」切换条：全部入口横排成一条带，纯图标，
/// 当前项居中、图标背后是该项专属的 M3E 多边形（[navShapeOf]，与侧栏同一套），
/// 其余缩小并按距离渐淡，两端渐隐暗示还有更多。名字只进 Tooltip 与 Semantics。
///
/// 横拨跟手平移；拖动过程中高亮实时落到「松手将会到达的那一项」，每换到新的
/// 一项轻震一次，松手才吸附并跳转。高亮在两项之间移动是液态墨滴（前沿先走、
/// 后沿后到，拉长时收细），落定后由圆变形成目标项的多边形。点邻居直接切过去。
/// 墨水屏 / 减弱动态效果下高亮直接落位、不做墨滴与变形。
class NavModeStripBar extends StatefulWidget {
  const NavModeStripBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavModeStripBar> createState() => _NavModeStripBarState();
}

/// 一格的宽度（≥48dp 命中区），也是拖动换格的步长：拖过一格宽 = 换一项。
const double _kSlotWidth = 52;

/// 轻拨超过这个距离也至少换一格。
const double _kMinFlick = 24;

const double _kItemHeight = 52;
const double _kIconSize = 24;

/// 高亮多边形（与墨滴）的边长：比格子小一圈，留出相邻多边形之间的呼吸。
const double _kShapeSize = 46;

class _NavModeStripBarState extends State<NavModeStripBar>
    with TickerProviderStateMixin {
  /// 切换动画（0→1，弹簧曲线）：sel 从 [_fromSel] 走到 [_toSel]，
  /// 松手残留的拖动位移 [_fromDrag] 同步归零。
  late final AnimationController _move = AnimationController(vsync: this);

  /// 高亮在两格之间流动（0→1，弹簧曲线）：从 [_hlFrom] 流到 [_hlTo]。
  late final AnimationController _flow = AnimationController(vsync: this);

  /// 当前项是否在条带里（不在 = 当前页是 FAB 那一项，不画高亮）。
  late final AnimationController _presence = AnimationController(vsync: this);

  /// 已提交的当前项（[NavOverflowSpec.indices] 里的位置）。
  int _committed = 0;
  double _fromSel = 0;
  double _toSel = 0;
  double _fromDrag = 0;

  /// 高亮所在的格（拖动中是预览目标，静止时等于 [_committed]）。
  int _hlTarget = 0;
  double _hlFrom = 0;
  double _hlTo = 0;

  bool _dragging = false;
  double _liveDrag = 0;

  static const Curve _spring = FushiSpringCurve.spatialFast;

  NavOverflowSpec get spec => widget.spec;

  @override
  void initState() {
    super.initState();
    final int pos = spec.indices.indexOf(spec.currentIndex);
    _committed = pos < 0 ? 0 : pos;
    _fromSel = _toSel = _committed.toDouble();
    _hlTarget = _committed;
    _hlFrom = _hlTo = _committed.toDouble();
    _move.value = 1;
    _flow.value = 1;
    _presence.value = pos < 0 ? 0 : 1;
  }

  @override
  void didUpdateWidget(NavModeStripBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int last = spec.indices.length - 1;
    if (_committed > last) _committed = math.max(0, last);
    final int pos = spec.indices.indexOf(spec.currentIndex);
    if (!_dragging) _animatePresence(pos >= 0);
    // 外部切页（或自己 onSelect 的回声）：目标不同才重新滚动。
    if (pos >= 0 && pos != _committed && !_dragging) {
      _committed = pos;
      _startMove(pos.toDouble());
      _flowTo(pos, rebuild: false);
    } else if (_toSel > last) {
      _startMove(_committed.toDouble());
      _flowTo(_committed, rebuild: false);
    } else if (_hlTarget > last) {
      _flowTo(math.max(0, last), rebuild: false);
    }
  }

  @override
  void dispose() {
    _move.dispose();
    _flow.dispose();
    _presence.dispose();
    super.dispose();
  }

  double get _t => _spring.transform(_move.value);

  /// 当前视觉上的连续位置（可过冲）。
  double get _visualSel => lerpDouble(_fromSel, _toSel, _t)!;

  /// 当前视觉上的拖动位移。
  double get _visualDrag => _dragging ? _liveDrag : _fromDrag * (1 - _t);

  /// 高亮流动进度（弹簧，可过冲）。
  double get _flowT => _spring.transform(_flow.value);

  /// 高亮视觉上的连续位置（格号，可过冲）。
  double get _visualHl => lerpDouble(_hlFrom, _hlTo, _flowT)!;

  bool get _flowing => _flow.isAnimating;

  void _animatePresence(bool present) {
    final double target = present ? 1 : 0;
    if (_presence.value == target && !_presence.isAnimating) return;
    _presence.duration = fushiMotionDuration(context, FushiMotion.medium);
    _presence.animateTo(target, curve: FushiMotion.standard);
  }

  /// 从当前视觉状态出发滚到 [target]，残余拖动位移一起收回。
  void _startMove(double target) {
    final double sel = _visualSel;
    final double drag = _visualDrag;
    _fromSel = sel;
    _fromDrag = drag;
    _toSel = target;
    _move.duration = fushiMotionDuration(context, FushiMotion.long);
    _move.forward(from: 0);
  }

  /// 高亮从当前视觉位置流到第 [target] 格（同一格不动）。[rebuild] 为
  /// false 时不 setState（didUpdateWidget 里调，框架随后本来就会 build）。
  void _flowTo(int target, {bool rebuild = true}) {
    if (target == _hlTarget && !_flowing) return;
    final double from = _visualHl;
    void apply() {
      _hlTarget = target;
      _hlFrom = from;
      _hlTo = target.toDouble();
    }

    if (rebuild) {
      setState(apply);
    } else {
      apply();
    }
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    if (duration == Duration.zero) {
      _flow.value = 1;
      return;
    }
    _flow.duration = duration;
    _flow.forward(from: 0);
  }

  void _select(int pos) {
    final int last = spec.indices.length - 1;
    final int target = pos.clamp(0, last).toInt();
    final bool changed = target != _committed;
    _committed = target;
    _startMove(target.toDouble());
    _flowTo(target);
    _animatePresence(true);
    if (changed || spec.currentIndex != spec.indices[target]) {
      spec.onSelect(spec.indices[target]);
    }
  }

  /// 以拖动位移 [drag]、松手速度 [velocity] 松手时将到达的格。拖动中用
  /// velocity = 0 预览，与真正松手同一套判据，预览与落点不会对不上（只有
  /// 甩动速度会在松手那一下多推一格）。
  int _releaseTarget(double drag, double velocity) {
    int target = (_visualSel - drag / _kSlotWidth).round();
    if (target == _committed) {
      if (drag.abs() > _kMinFlick) {
        target = _committed - drag.sign.toInt();
      } else if (velocity.abs() > 400) {
        target = _committed - velocity.sign.toInt();
      }
    }
    return target.clamp(0, spec.indices.length - 1).toInt();
  }

  void _onDragStart(DragStartDetails details) {
    final double sel = _visualSel;
    final double drag = _visualDrag;
    _move.stop();
    setState(() {
      _fromSel = _toSel = sel;
      _move.value = 1;
      _dragging = true;
      _liveDrag = drag;
    });
    // 当前页是 FAB 那一项时高亮本来不在：拖起来就亮出预览。
    _animatePresence(true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double dx = details.primaryDelta ?? details.delta.dx;
    final int last = spec.indices.length - 1;
    // 拨出两端时加阻尼，提示到头了。
    final double projected = _visualSel - (_liveDrag + dx) / _kSlotWidth;
    final bool beyond = projected < -0.5 || projected > last + 0.5;
    setState(() => _liveDrag += beyond ? dx / 3 : dx);
    final int preview = _releaseTarget(_liveDrag, 0);
    if (preview != _hlTarget) {
      // 预览目标换到新的一项：轻震一次，高亮流过去。
      fushiSelectionHaptic(context);
      _flowTo(preview);
    }
  }

  void _onDragEnd(DragEndDetails details) {
    final double drag = _liveDrag;
    final double velocity = details.primaryVelocity ?? 0;
    final int clamped = _releaseTarget(drag, velocity);
    setState(() => _dragging = false);
    _fromDrag = drag;
    _flowTo(clamped);
    if (clamped == _committed && spec.currentIndex == spec.indices[clamped]) {
      // 没换格：只吸附回原位。
      final double sel = _visualSel;
      _fromSel = sel;
      _toSel = _committed.toDouble();
      _move.duration = fushiMotionDuration(context, FushiMotion.long);
      _move.forward(from: 0);
      return;
    }
    _committed = clamped;
    _fromSel = _visualSel;
    _toSel = clamped.toDouble();
    _move.duration = fushiMotionDuration(context, FushiMotion.long);
    _move.forward(from: 0);
    _animatePresence(true);
    spec.onSelect(spec.indices[clamped]);
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _onDragEnd(DragEndDetails(primaryVelocity: 0));
  }

  @override
  Widget build(BuildContext context) {
    if (spec.indices.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: spec.width,
      height: spec.height,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (Rect bounds) => const LinearGradient(
          colors: <Color>[
            Color(0x00000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          stops: <double>[0, 0.2, 0.8, 1],
        ).createShader(bounds),
        child: ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
            child: AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[
                _move,
                _flow,
                _presence,
              ]),
              builder: (BuildContext context, Widget? _) =>
                  _buildTrack(context),
            ),
          ),
        ),
      ),
    );
  }

  /// 第 [slot] 格（可为小数）高亮方块在条带坐标里的矩形。
  Rect _shapeRect(double slot, double top) {
    final double cx = slot * _kSlotWidth + _kSlotWidth / 2;
    final double cy = top + _kItemHeight / 2;
    return Rect.fromCenter(
      center: Offset(cx, cy),
      width: _kShapeSize,
      height: _kShapeSize,
    );
  }

  Widget _buildTrack(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int count = spec.indices.length;
    final double sel = _visualSel;
    final double hl = _visualHl;
    final double presence = _presence.value.clamp(0.0, 1.0).toDouble();

    final double offset =
        spec.width / 2 - (sel * _kSlotWidth + _kSlotWidth / 2) + _visualDrag;
    final double top = (spec.height - _kItemHeight) / 2;

    // 流动中画液态墨滴；落定后由目标项的多边形接手（圆 → 多边形）。
    final Rect blob = _liquidRect(
      _shapeRect(_hlFrom, top),
      _shapeRect(_hlTo, top),
      _flowT,
    ).shift(Offset(offset, 0));
    final Rect landed = _shapeRect(
      _hlTarget.toDouble(),
      top,
    ).shift(Offset(offset, 0));

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        if (_flowing)
          Positioned.fromRect(
            rect: blob,
            child: IgnorePointer(
              child: Opacity(
                opacity: presence,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.tertiary,
                    borderRadius: BorderRadius.circular(
                      math.min(blob.width, blob.height) / 2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned.fromRect(
          rect: landed,
          child: IgnorePointer(
            child: Opacity(
              opacity: presence,
              child: NavMorphShape(
                shape: navShapeOf(spec.items, spec.indices[_hlTarget]),
                visible: !_flowing && presence > 0,
                color: scheme.tertiary,
                size: _kShapeSize,
              ),
            ),
          ),
        ),
        for (int p = 0; p < count; p++)
          Positioned(
            left: offset + p * _kSlotWidth,
            top: top,
            width: _kSlotWidth,
            height: _kItemHeight,
            child: _buildItem(
              position: p,
              item: spec.item(spec.indices[p]),
              // 图标前景随高亮经过渐变：墨滴罩到哪项，哪项就换成选中前景色。
              expand:
                  (1 - (hl - p).abs()).clamp(0.0, 1.0).toDouble() * presence,
              distance: (sel - _visualDrag / _kSlotWidth - p).abs(),
              scheme: scheme,
            ),
          ),
      ],
    );
  }

  /// 液态墨滴在进度 [t] 时的矩形（思路同 adaptive_navigation 的
  /// `_SlidingIndicatorPainter._liquidRect`，这里只走横向）：前沿按
  /// `1-(1-t)²`、后沿按 `t²` 走，两沿在 t = 1 汇合（之后的弹簧过冲两沿同步，
  /// 落点回弹）；拉得越长纵向越细，位移越远收得越多（最多收到 65%）。
  static Rect _liquidRect(Rect a, Rect b, double t) {
    if (t >= 1 || t <= 0) return Rect.lerp(a, b, t)!;
    final double lead = 1 - (1 - t) * (1 - t);
    final double trail = t * t;
    final double distance = (b.center.dx - a.center.dx).abs();
    final double thin =
        1 - 0.35 * (lead - trail) * 2 * (distance / 240).clamp(0.0, 1.0);
    double edge(double from, double to, double p) => from + (to - from) * p;
    final bool right = b.center.dx >= a.center.dx;
    final double left = edge(a.left, b.left, right ? trail : lead);
    final double rightEdge = edge(a.right, b.right, right ? lead : trail);
    final double cy = edge(a.center.dy, b.center.dy, t);
    final double h = edge(a.height, b.height, t) * thin;
    return Rect.fromLTRB(left, cy - h / 2, rightEdge, cy + h / 2);
  }

  Widget _buildItem({
    required int position,
    required AdaptiveNavItem item,
    required double expand,
    required double distance,
    required ColorScheme scheme,
  }) {
    final Color color = Color.lerp(
      scheme.onTertiaryContainer,
      scheme.onTertiary,
      expand,
    )!;
    // 邻居缩到 0.9、按离中线的距离渐淡（两端再由 ShaderMask 渐隐）。
    final double scale = 0.9 + 0.1 * expand;
    final double opacity = (1 - 0.25 * distance.clamp(0.0, 3.0))
        .clamp(0.25, 1.0)
        .toDouble();
    final bool selected =
        position == _committed && spec.currentIndex == spec.indices[position];

    final Widget content = Opacity(
      opacity: math.max(opacity, expand),
      child: Transform.scale(
        scale: scale,
        child: FushiIcon(
          expand > 0.5 ? (item.selectedIcon ?? item.icon) : item.icon,
          size: _kIconSize,
          color: color,
        ),
      ),
    );

    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: FushiTooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(position),
          child: Center(child: content),
        ),
      ),
    );
  }
}
