import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 底栏原型「相机模式条」（[AdaptiveNavBarStyle] 同名值，设计稿 F5）。
///
/// 借相机 App「照片 / 视频 / 人像」切换条：全部入口横排成一条带，当前项是
/// 居中的一颗 tertiary 胶囊（图标 + 名字），其余只有图标、缩小并按距离渐淡，
/// 两端渐隐暗示还有更多。横拨跟手平移，松手吸附到新的当前项并立即跳转；
/// 点邻居直接切过去。
///
/// **注意：本原型有意让当前项显示文字名字**，与仓库「主导航底栏默认纯图标」
/// 规则冲突——这是待用户拍板的交互原型，定稿前不得当作规则例外推广。邻居只画
/// 图标，名字进 Tooltip 与 Semantics。
class NavModeStripBar extends StatefulWidget {
  const NavModeStripBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavModeStripBar> createState() => _NavModeStripBarState();
}

/// 一格（无名字时）的宽度，也是拖动换格的步长参考。
const double _kSlotWidth = 52;

/// 每多少逻辑像素位移换一格。
const double _kDragStep = 56;

/// 轻拨超过这个距离也至少换一格。
const double _kMinFlick = 24;

const double _kItemHeight = 52;
const double _kIconSize = 24;
const double _kPadding = 14;
const double _kGap = 8;
const double _kMaxLabelWidth = 96;

class _NavModeStripBarState extends State<NavModeStripBar>
    with TickerProviderStateMixin {
  /// 切换动画（0→1，弹簧曲线）：sel 从 [_fromSel] 走到 [_toSel]，
  /// 松手残留的拖动位移 [_fromDrag] 同步归零。
  late final AnimationController _move = AnimationController(vsync: this);

  /// 当前项是否在条带里（不在 = 当前页是 FAB 那一项，不画胶囊与名字）。
  late final AnimationController _presence = AnimationController(vsync: this);

  /// 已提交的当前项（[NavOverflowSpec.indices] 里的位置）。
  int _committed = 0;
  double _fromSel = 0;
  double _toSel = 0;
  double _fromDrag = 0;

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
    _move.value = 1;
    _presence.value = pos < 0 ? 0 : 1;
  }

  @override
  void didUpdateWidget(NavModeStripBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int last = spec.indices.length - 1;
    if (_committed > last) _committed = math.max(0, last);
    final int pos = spec.indices.indexOf(spec.currentIndex);
    _animatePresence(pos >= 0);
    // 外部切页（或自己 onSelect 的回声）：目标不同才重新滚动。
    if (pos >= 0 && pos != _committed) {
      _committed = pos;
      _startMove(pos.toDouble());
    } else if (_toSel > last) {
      _startMove(_committed.toDouble());
    }
  }

  @override
  void dispose() {
    _move.dispose();
    _presence.dispose();
    super.dispose();
  }

  double get _t => _spring.transform(_move.value);

  /// 当前视觉上的连续位置（可过冲）。
  double get _visualSel => lerpDouble(_fromSel, _toSel, _t)!;

  /// 当前视觉上的拖动位移。
  double get _visualDrag => _dragging ? _liveDrag : _fromDrag * (1 - _t);

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

  void _select(int pos) {
    final int last = spec.indices.length - 1;
    final int target = pos.clamp(0, last).toInt();
    final bool changed = target != _committed;
    _committed = target;
    _startMove(target.toDouble());
    _animatePresence(true);
    if (changed || spec.currentIndex != spec.indices[target]) {
      spec.onSelect(spec.indices[target]);
    }
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
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double dx = details.primaryDelta ?? details.delta.dx;
    final int last = spec.indices.length - 1;
    // 拨出两端时加阻尼，提示到头了。
    final double projected = _visualSel - (_liveDrag + dx) / _kDragStep;
    final bool beyond = projected < -0.5 || projected > last + 0.5;
    setState(() => _liveDrag += beyond ? dx / 3 : dx);
  }

  void _onDragEnd(DragEndDetails details) {
    final double drag = _liveDrag;
    final double velocity = details.primaryVelocity ?? 0;
    int target = (_visualSel - drag / _kDragStep).round();
    if (target == _committed) {
      if (drag.abs() > _kMinFlick) {
        target = _committed - drag.sign.toInt();
      } else if (velocity.abs() > 400) {
        target = _committed - velocity.sign.toInt();
      }
    }
    setState(() => _dragging = false);
    _fromDrag = drag;
    final int last = spec.indices.length - 1;
    final int clamped = target.clamp(0, last).toInt();
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
    final TextStyle labelStyle = context.fushiType.labelLarge.copyWith(
      fontWeight: FontWeight.w700,
      height: 1,
    );
    final List<double> labelWidths = _measureLabels(
      labelStyle,
      MediaQuery.textScalerOf(context),
    );
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
              animation: Listenable.merge(<Listenable>[_move, _presence]),
              builder: (BuildContext context, Widget? _) =>
                  _buildTrack(context, labelWidths, labelStyle),
            ),
          ),
        ),
      ),
    );
  }

  List<double> _measureLabels(TextStyle style, TextScaler scaler) {
    return <double>[
      for (final int i in spec.indices)
        _measure(spec.item(i).label, style, scaler),
    ];
  }

  double _measure(String text, TextStyle style, TextScaler scaler) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final double width = painter.width;
    painter.dispose();
    return math.min(width.ceilToDouble(), _kMaxLabelWidth);
  }

  Widget _buildTrack(
    BuildContext context,
    List<double> labelWidths,
    TextStyle labelStyle,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int count = spec.indices.length;
    final double sel = _visualSel;
    final double presence = _presence.value.clamp(0.0, 1.0).toDouble();

    // 每项的展开度：离视觉位置越近越展开（胶囊在两项之间时两边各分一部分）。
    final List<double> expand = <double>[
      for (int p = 0; p < count; p++)
        (1 - (sel - p).abs()).clamp(0.0, 1.0).toDouble() * presence,
    ];
    final List<double> widths = <double>[
      for (int p = 0; p < count; p++)
        _kSlotWidth + expand[p] * (labelWidths[p] + _kGap),
    ];
    final List<double> lefts = List<double>.filled(count, 0);
    double x = 0;
    for (int p = 0; p < count; p++) {
      lefts[p] = x;
      x += widths[p];
    }

    // 胶囊矩形：在相邻两项之间插值（sel 过冲到两端外时按端点外推）。
    final double clampedSel = sel.clamp(0.0, (count - 1).toDouble()).toDouble();
    final int lo = clampedSel.floor();
    final int hi = math.min(lo + 1, count - 1);
    final double frac = clampedSel - lo;
    final double overshoot = (sel - clampedSel) * _kSlotWidth;
    final double pillLeft = lerpDouble(lefts[lo], lefts[hi], frac)! + overshoot;
    final double pillWidth = lerpDouble(widths[lo], widths[hi], frac)!;
    final double pillCenter = pillLeft + pillWidth / 2;

    final double offset = spec.width / 2 - pillCenter + _visualDrag;
    final double top = (spec.height - _kItemHeight) / 2;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          left: offset + pillLeft,
          top: top,
          width: pillWidth,
          height: _kItemHeight,
          child: IgnorePointer(
            child: Opacity(
              opacity: presence,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.tertiary,
                  borderRadius: BorderRadius.circular(_kItemHeight / 2),
                ),
              ),
            ),
          ),
        ),
        for (int p = 0; p < count; p++)
          Positioned(
            left: offset + lefts[p],
            top: top,
            width: widths[p],
            height: _kItemHeight,
            child: _buildItem(
              position: p,
              item: spec.item(spec.indices[p]),
              expand: expand[p],
              distance: (sel - p).abs(),
              labelWidth: labelWidths[p],
              labelStyle: labelStyle,
              scheme: scheme,
            ),
          ),
      ],
    );
  }

  Widget _buildItem({
    required int position,
    required AdaptiveNavItem item,
    required double expand,
    required double distance,
    required double labelWidth,
    required TextStyle labelStyle,
    required ColorScheme scheme,
  }) {
    final Color color = Color.lerp(
      scheme.onTertiaryContainer,
      scheme.onTertiary,
      expand,
    )!;
    // 邻居缩到 0.9、按距离渐淡（两端再由 ShaderMask 渐隐）。
    final double scale = 0.9 + 0.1 * expand;
    final double opacity = (1 - 0.25 * distance.clamp(0.0, 3.0))
        .clamp(0.25, 1.0)
        .toDouble();
    final bool selected =
        position == _committed && spec.currentIndex == spec.indices[position];
    final double labelSlot = expand * (labelWidth + _kGap);

    Widget content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIcon(
          expand > 0.5 ? (item.selectedIcon ?? item.icon) : item.icon,
          size: _kIconSize,
          color: color,
        ),
        SizedBox(
          width: labelSlot,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: labelWidth + _kGap,
              child: Padding(
                padding: const EdgeInsets.only(left: _kGap),
                child: Opacity(
                  opacity: expand.clamp(0.0, 1.0).toDouble(),
                  child: SizedBox(
                    width: labelWidth,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle.copyWith(color: color),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    content = Opacity(
      opacity: opacity,
      child: Transform.scale(scale: scale, child: content),
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _kPadding - 12),
            child: Center(child: content),
          ),
        ),
      ),
    );
  }
}
