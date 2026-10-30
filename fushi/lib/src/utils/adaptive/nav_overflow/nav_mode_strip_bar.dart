import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/focus/fushi_focus_target.dart';
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

/// 底栏原型「相机模式条」（[AdaptiveNavBarStyle] 同名值，设计稿 F5）。
///
/// 借相机 App「照片 / 视频 / 人像」切换条：全部入口横排成一条带，纯图标，
/// 当前项图标背后是该项专属的 M3E 多边形（[navShapeOf]，与侧栏同一套），下方
/// 一枚底标跟着高亮走。名字只进 Tooltip 与 Semantics。
///
/// 条带铺满胶囊宽度（2026-10-25 用户「像圆柱滚筒一样显示范围更宽、最左最右
/// 不要留白」）：格宽 = 胶囊宽 ÷ 放得下的格数（[navModeStripSlotWidth]），全部
/// 放得下时等分铺满、不滚动；放不下时条带跟着当前项滚，但首尾项贴住胶囊边、
/// 两端不露空白（[navModeStripTrackOffset] 夹紧），只有那一侧还有项藏着时才
/// 渐隐提示。
///
/// 横拨跟手；拖动过程中高亮实时落到「松手将会到达的那一项」，每换到新的
/// 一项轻震一次，松手才吸附并跳转。高亮在两项之间移动是液态墨滴（前沿先走、
/// 后沿后到，拉长时收细），落定后由圆变形成目标项的多边形。点邻居直接切过去。
/// 墨水屏 / 减弱动态效果下高亮直接落位、不做墨滴与变形。
///
/// Apple 设计系统（2026-10-30）：同一套交互，高亮换成 Apple 标签栏同款的
/// 圆形中性 lens、选中图标着强调色，不画 M3E 多边形（见 [NavOverflowPalette]）。
///
/// 键盘 / 手柄：[NavOverflowSpec.focusIdPrefix] 非空时每一项登记成
/// `<前缀>-<序号>` 焦点目标（Enter / A 切过去）；焦点停到藏在胶囊外的项时
/// 条带先滚过去露出它，焦点离开条带后滚回当前项。
class NavModeStripBar extends StatefulWidget {
  const NavModeStripBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavModeStripBar> createState() => _NavModeStripBarState();
}

/// 一格的最小宽度（≥48dp 命中区）。实际格宽按胶囊宽度均分
/// （[navModeStripSlotWidth]），也是拖动换格的步长：拖过一格宽 = 换一项。
const double _kMinSlotWidth = 52;

/// 轻拨超过这个距离也至少换一格。
const double _kMinFlick = 24;

const double _kItemHeight = 52;
const double _kIconSize = 24;

/// 高亮多边形（与墨滴）的边长：比格子小一圈，留出相邻多边形之间的呼吸。
const double _kShapeSize = 46;

/// 底标（高亮下方的短横，沿用圆柱滚筒的底标）的尺寸与离胶囊底边的距离。
const double _kMarkerWidth = 16;
const double _kMarkerHeight = 3;
const double _kMarkerBottom = 2;

/// 两端渐隐带占胶囊宽度的比例（只在那一侧还有藏着的项时画）。
const double _kEdgeFade = 0.16;

/// 宽 [width] 的胶囊里放 [count] 项时的格宽：能放下的格数
/// n = ⌊width / 52⌋（至少 1），项数不超过 n 时按项数等分铺满，否则按 n 等分
/// （每格仍 ≥ 52，条带横拨滚动）。
double navModeStripSlotWidth(double width, int count) {
  if (count <= 0 || width <= 0) return _kMinSlotWidth;
  final int fit = math.max(1, (width / _kMinSlotWidth).floor());
  return width / math.min(fit, count);
}

/// 条带最左端相对胶囊左边的位移：想让第 [sel] 格（可为小数）居中、再加拖动
/// 位移 [drag]，然后夹到 [width − 条带总宽, 0]——首尾项贴边，两端不留白；
/// 全部放得下时恒为 0。
double navModeStripTrackOffset({
  required double width,
  required int count,
  required double sel,
  required double drag,
}) {
  final double slot = navModeStripSlotWidth(width, count);
  final double minOffset = math.min(0, width - count * slot);
  final double centred = width / 2 - (sel * slot + slot / 2) + drag;
  return centred.clamp(minOffset, 0.0).toDouble();
}

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

  /// 键盘 / 手柄焦点此刻停在哪一格（null = 不在条带里）。
  int? _focusedPos;

  static const Curve _spring = FushiSpringCurve.spatialFast;

  NavOverflowSpec get spec => widget.spec;

  double get _slot => navModeStripSlotWidth(spec.width, spec.indices.length);

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
    int target = (_visualSel - drag / _slot).round();
    if (target == _committed) {
      if (drag.abs() > _kMinFlick) {
        target = _committed - drag.sign.toInt();
      } else if (velocity.abs() > 400) {
        target = _committed - velocity.sign.toInt();
      }
    }
    return target.clamp(0, spec.indices.length - 1).toInt();
  }

  /// 焦点进 / 出第 [pos] 格：进来时条带滚到它（不切页），焦点离开整条后滚回
  /// 已提交的当前项。焦点在两格之间移动时先报旧格失焦、再报新格得焦，所以
  /// 「离开整条」放到微任务里判。
  void _onItemFocusChange(int pos, bool focused) {
    if (focused) {
      // 同一格重复报得焦（选中后整条重建、焦点节点换新时会再报一次）不是
      // 「焦点走进来」：再滚一次会把刚点选的当前项从条带中间拽回焦点格。
      if (_focusedPos == pos) return;
      _focusedPos = pos;
      if (!_dragging) _startMove(pos.toDouble());
      return;
    }
    if (_focusedPos != pos) return;
    _focusedPos = null;
    scheduleMicrotask(() {
      if (!mounted || _focusedPos != null || _dragging) return;
      if (_toSel != _committed.toDouble()) _startMove(_committed.toDouble());
    });
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
    final double projected = _visualSel - (_liveDrag + dx) / _slot;
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
      child: ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: _onDragCancel,
          child: AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[_move, _flow, _presence]),
            builder: (BuildContext context, Widget? _) => _buildFaded(context),
          ),
        ),
      ),
    );
  }

  /// 条带外包一层两端渐隐：只有那一侧还有项藏在胶囊外时才渐隐（藏得越多
  /// 越淡，满一格封顶），首尾贴边时那一端完全不透明、不留白。
  Widget _buildFaded(BuildContext context) {
    final int count = spec.indices.length;
    final double slot = _slot;
    final double offset = navModeStripTrackOffset(
      width: spec.width,
      count: count,
      sel: _visualSel,
      drag: _visualDrag,
    );
    final double hiddenLeft = (-offset / slot).clamp(0.0, 1.0).toDouble();
    final double hiddenRight = ((count * slot + offset - spec.width) / slot)
        .clamp(0.0, 1.0)
        .toDouble();
    final Widget track = _buildTrack(context, offset);
    if (hiddenLeft == 0 && hiddenRight == 0) return track;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) => LinearGradient(
        colors: <Color>[
          Color.fromRGBO(0, 0, 0, 1 - hiddenLeft),
          const Color(0xFF000000),
          const Color(0xFF000000),
          Color.fromRGBO(0, 0, 0, 1 - hiddenRight),
        ],
        stops: const <double>[0, _kEdgeFade, 1 - _kEdgeFade, 1],
      ).createShader(bounds),
      child: track,
    );
  }

  /// 第 [slot] 格（可为小数）高亮方块在条带坐标里的矩形。
  Rect _shapeRect(double slot, double top) {
    final double cx = slot * _slot + _slot / 2;
    final double cy = top + _kItemHeight / 2;
    return Rect.fromCenter(
      center: Offset(cx, cy),
      width: _kShapeSize,
      height: _kShapeSize,
    );
  }

  Widget _buildTrack(BuildContext context, double offset) {
    final NavOverflowPalette palette = NavOverflowPalette.of(context);
    final int count = spec.indices.length;
    final double slot = _slot;
    final double sel = _visualSel;
    final double hl = _visualHl;
    final double presence = _presence.value.clamp(0.0, 1.0).toDouble();

    final double top = (spec.height - _kItemHeight) / 2;
    // 底标跟着高亮的视觉位置走（墨滴流动时一起滑，过冲同步）。
    final double markerCenter = offset + hl * slot + slot / 2;

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
                    color: palette.highlight,
                    border: palette.highlightRim,
                    boxShadow: palette.highlightShadows,
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
              child: palette.polygons
                  ? NavMorphShape(
                      shape: navShapeOf(spec.items, spec.indices[_hlTarget]),
                      visible: !_flowing && presence > 0,
                      color: palette.highlight,
                      size: _kShapeSize,
                    )
                  // Apple：落定后就是墨滴静止时的那枚圆 lens（与平铺标签栏
                  // 同款），不再变形。
                  : Visibility.maintain(
                      visible: !_flowing && presence > 0,
                      child: DecoratedBox(
                        key: const ValueKey<String>('nav-mode-strip-lens'),
                        decoration: BoxDecoration(
                          color: palette.highlight,
                          shape: BoxShape.circle,
                          border: palette.highlightRim,
                          boxShadow: palette.highlightShadows,
                        ),
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          left: markerCenter - _kMarkerWidth / 2,
          bottom: _kMarkerBottom,
          width: _kMarkerWidth,
          height: _kMarkerHeight,
          child: IgnorePointer(
            child: Opacity(
              opacity: presence,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.content.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        for (int p = 0; p < count; p++)
          Positioned(
            left: offset + p * slot,
            top: top,
            width: slot,
            height: _kItemHeight,
            child: _buildItem(
              position: p,
              item: spec.item(spec.indices[p]),
              // 图标前景随高亮经过渐变：墨滴罩到哪项，哪项就换成选中前景色。
              expand:
                  (1 - (hl - p).abs()).clamp(0.0, 1.0).toDouble() * presence,
              distance: (sel - _visualDrag / slot - p).abs(),
              palette: palette,
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
    required NavOverflowPalette palette,
  }) {
    final Color color = Color.lerp(
      palette.content,
      palette.onHighlight,
      expand,
    )!;
    // 邻居缩到 0.9、按离当前项的距离轻微渐淡（铺满整条，远处也看得清；
    // 还藏着项的那一端再由 ShaderMask 渐隐）。
    final double scale = 0.9 + 0.1 * expand;
    final double opacity = (1 - 0.12 * distance.clamp(0.0, 4.0))
        .clamp(0.5, 1.0)
        .toDouble();
    final bool selected =
        position == _committed && spec.currentIndex == spec.indices[position];

    final Widget glyph = Opacity(
      opacity: math.max(opacity, expand),
      child: Transform.scale(
        scale: scale,
        child: FushiBadgeControl(
          isLabelVisible: item.experimentalBadge,
          child: FushiIcon(
            expand > 0.5 ? (item.selectedIcon ?? item.icon) : item.icon,
            size: _kIconSize,
            color: color,
          ),
        ),
      ),
    );

    // 焦点框包住与高亮同大的方块（不是只包 24 的图标）。
    Widget content = SizedBox.square(
      dimension: _kShapeSize,
      child: Center(child: glyph),
    );
    final FushiFocusId? focusId = spec.focusIdOf(spec.indices[position]);
    if (focusId != null) {
      // ActivateIntent 必须挂在焦点节点之上（手柄 / 键盘从主焦点往上找 Actions）。
      content = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (bool focused) => _onItemFocusChange(position, focused),
        child: Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (ActivateIntent intent) {
                _select(position);
                return null;
              },
            ),
          },
          child: FushiFocusTarget(id: focusId, child: content),
        ),
      );
    }

    // excludeSemantics 会连带吞掉下层 GestureDetector 的点按动作，读屏点不动：
    // 点按动作挂在这一层。
    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      onTap: () => _select(position),
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
