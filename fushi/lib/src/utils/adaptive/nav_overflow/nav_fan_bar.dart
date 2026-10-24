import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, PointerEnterEvent, PointerExitEvent;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 牌叠格宽（与 [NavOverflowSpec.pinnedCount] 的 triggerWidth 一致）。
const double _kDeckWidth = 56;

/// 支点在屏幕底边以下的距离。
const double _kPivotBelow = 140;

/// 支点到牌顶的臂长。
const double _kArm = 330;
const double _kCardWidth = 64;
const double _kCardHeight = 92;
const double _kCardRadius = 12;

/// 扇面总张角的一半（度）。
const double _kSpreadDeg = 28;

/// 抽起的牌上移量与放大倍率。
const double _kHotLift = 30;
const double _kHotScale = 0.12;

/// 按住牌叠上移超过这么多才算「拖开」。
const double _kDragOpenThreshold = 12;

/// 点按判定：按下到抬起位移不超过它。
const double _kTapSlop = 18;

/// 单张牌弹出时长与按离中心距离的错峰步长（毫秒）。
const int _kCardPopMs = 500;
const int _kStaggerStepMs = 18;
const int _kCloseMs = 260;

/// 底栏原型「纸牌扇」（[AdaptiveNavBarStyle] 同名值）。
///
/// 胶囊里平铺放得下的固定项，最后一格是一小叠扑克；按住牌叠上拖，全部目的地
/// 像一手牌从屏幕底部中线下方的支点扇开，手指指到哪张抽哪张，松手打出；轻点
/// 牌叠则扇开停住，点牌跳转、点遮罩收起。
class NavFanBar extends StatefulWidget {
  const NavFanBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavFanBar> createState() => _NavFanBarState();
}

class _NavFanBarState extends State<NavFanBar>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _overlayKey = GlobalKey();
  late final AnimationController _fan = AnimationController(vsync: this)
    ..addStatusListener(_onFanStatus);

  /// 扇面是否处于「打开」意图（关闭动画进行中为 false）。
  bool _open = false;

  /// 当前手势是否是「按住上拖选牌」。
  bool _dragMode = false;

  /// 抽起的那张（[NavOverflowSpec.items] 序号）。
  int? _hot;

  bool _deckPressed = false;
  bool _deckHovered = false;

  int? _pointer;
  Offset _downPosition = Offset.zero;

  NavOverflowSpec get _spec => widget.spec;

  int get _cardCount => _spec.indices.length;

  int get _maxStaggerMs {
    final double half = (_cardCount - 1) / 2;
    return (half * _kStaggerStepMs).round();
  }

  @override
  void dispose() {
    _fan.dispose();
    super.dispose();
  }

  void _onFanStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _portal.isShowing) {
      _portal.hide();
    }
  }

  // ---------------------------------------------------------------- 开合

  void _openFan() {
    if (_open) return;
    _fan.duration = fushiMotionDuration(
      context,
      Duration(milliseconds: _kCardPopMs + _maxStaggerMs),
    );
    _fan.reverseDuration = fushiMotionDuration(
      context,
      const Duration(milliseconds: _kCloseMs),
    );
    if (!_portal.isShowing) _portal.show();
    setState(() {
      _open = true;
      _hot = null;
    });
    _fan.forward();
  }

  void _closeFan() {
    if (!_open && !_portal.isShowing) return;
    setState(() {
      _open = false;
      _dragMode = false;
      _hot = null;
    });
    _fan.reverse();
  }

  void _play(int index) {
    _closeFan();
    _spec.onSelect(index);
  }

  void _setHot(int? index) {
    if (index == _hot) return;
    if (index != null) fushiSelectionHaptic(context);
    setState(() => _hot = index);
  }

  // ------------------------------------------------------------ 几何

  /// 第 [slot] 张（扇面从左到右的位置）的张角，单位弧度。
  double _angleOf(int slot) {
    if (_cardCount <= 1) return 0;
    final double deg =
        -_kSpreadDeg + slot * (2 * _kSpreadDeg / (_cardCount - 1));
    return deg * math.pi / 180;
  }

  /// 按手指在遮罩层里的位置挑最近的牌（返回扇面位置）；离所有牌都远返回 null。
  int? _slotAt(Offset local, Size size) {
    if (_cardCount == 0) return null;
    final Offset pivot = Offset(size.width / 2, size.height + _kPivotBelow);
    final double dx = local.dx - pivot.dx;
    final double dy = pivot.dy - local.dy;
    final double radius = math.sqrt(dx * dx + dy * dy);
    // 牌在 [臂长 - 牌高, 臂长 + 抽起量] 这一圈；放宽一些容错，但手指回到底栏
    // （半径明显小于牌底）或甩出牌顶很远都算「离开」。
    if (radius < _kArm - _kCardHeight - 30 || radius > _kArm + 120) {
      return null;
    }
    final double angle = math.atan2(dx, dy);
    final double step = _cardCount <= 1
        ? 16 * math.pi / 180
        : (2 * _kSpreadDeg / (_cardCount - 1)) * math.pi / 180;
    final double limit = _kSpreadDeg * math.pi / 180 + step / 2 + 0.06;
    if (angle.abs() > limit) return null;
    int best = 0;
    double bestDiff = double.infinity;
    for (int slot = 0; slot < _cardCount; slot++) {
      final double diff = (_angleOf(slot) - angle).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = slot;
      }
    }
    return best;
  }

  void _trackDrag(Offset globalPosition) {
    final RenderObject? box = _overlayKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final int? slot = _slotAt(box.globalToLocal(globalPosition), box.size);
    _setHot(slot == null ? null : _spec.indices[slot]);
  }

  // ------------------------------------------------------------ 指针

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downPosition = event.position;
    _dragMode = false;
    setState(() => _deckPressed = true);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if (!_dragMode &&
        _downPosition.dy - event.position.dy > _kDragOpenThreshold) {
      _dragMode = true;
      _openFan();
    }
    if (_dragMode) _trackDrag(event.position);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    setState(() => _deckPressed = false);
    if (_dragMode) {
      _dragMode = false;
      final int? hot = _hot;
      if (hot != null) {
        _play(hot);
      } else {
        _closeFan();
      }
      return;
    }
    if ((event.position - _downPosition).distance <= _kTapSlop) _openFan();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    setState(() => _deckPressed = false);
    if (_dragMode) _closeFan();
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final NavOverflowSpec spec = _spec;
    final int pinned = spec.pinnedCount(triggerWidth: _kDeckWidth);
    final List<int> pinnedIndices = spec.indices.take(pinned).toList();
    final List<int> hiddenIndices = spec.indices.skip(pinned).toList();
    final double cellWidth = pinnedIndices.isEmpty
        ? 0
        : (spec.width - _kDeckWidth) / pinnedIndices.length;
    final bool currentHidden = hiddenIndices.contains(spec.currentIndex);
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildOverlay,
      child: Row(
        children: <Widget>[
          for (final int i in pinnedIndices)
            Expanded(child: spec.cellBuilder(i, cellWidth)),
          _buildDeck(context, hiddenIndices, currentHidden),
        ],
      ),
    );
  }

  Widget _buildDeck(
    BuildContext context,
    List<int> hiddenIndices,
    bool currentHidden,
  ) {
    final List<int> labelSource = hiddenIndices.isEmpty
        ? _spec.indices
        : hiddenIndices;
    final String label = labelSource
        .map((int i) => _spec.item(i).label)
        .join(' · ');
    return FushiTooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        selected: currentHidden,
        onTap: _openFan,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (PointerEnterEvent _) => setState(() => _deckHovered = true),
          onExit: (PointerExitEvent _) => setState(() => _deckHovered = false),
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            // 一按下就赢下手势竞技场：胶囊外层的横拖 / 长按拖选识别器不能把
            // 牌叠上的手势抢走，上拖选牌全程由下面的 Listener 跟踪。
            gestures: <Type, GestureRecognizerFactory>{
              EagerGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                    EagerGestureRecognizer.new,
                    (EagerGestureRecognizer _) {},
                  ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: SizedBox(
                width: _kDeckWidth,
                height: math.max(48, _spec.height),
                child: Center(
                  child: _DeckGlyph(
                    spread: _deckPressed || _deckHovered || _open,
                    currentIcon: currentHidden
                        ? _spec.item(_spec.currentIndex).icon
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        key: _overlayKey,
        builder: (BuildContext context, BoxConstraints box) {
          final Size size = box.biggest;
          return AnimatedBuilder(
            animation: _fan,
            builder: (BuildContext context, Widget? _) =>
                _buildFan(context, size),
          );
        },
      ),
    );
  }

  /// 第 [slot] 张在当前开合进度下的弹出进度（带回弹，可略超 1）。
  double _popProgress(int slot) {
    final double total = (_kCardPopMs + _maxStaggerMs).toDouble();
    final double delay =
        (slot - (_cardCount - 1) / 2).abs() * _kStaggerStepMs.toDouble();
    final double local = ((_fan.value * total - delay) / _kCardPopMs).clamp(
      0.0,
      1.0,
    );
    return FushiSpringCurve.spatial.transform(local);
  }

  Widget _buildFan(BuildContext context, Size size) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Offset pivot = Offset(size.width / 2, size.height + _kPivotBelow);
    final List<int> order = <int>[
      for (int slot = 0; slot < _cardCount; slot++)
        if (_spec.indices[slot] != _hot) slot,
      for (int slot = 0; slot < _cardCount; slot++)
        if (_spec.indices[slot] == _hot) slot,
    ];
    final Duration hotDuration = fushiMotionDuration(
      context,
      const Duration(milliseconds: 250),
    );
    return IgnorePointer(
      ignoring: !_open,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeFan,
              child: ColoredBox(
                color: scheme.scrim.withValues(
                  alpha: 0.32 * _fan.value.clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
          for (final int slot in order)
            _positionedCard(
              context,
              slot: slot,
              pivot: pivot,
              hotDuration: hotDuration,
            ),
        ],
      ),
    );
  }

  Widget _positionedCard(
    BuildContext context, {
    required int slot,
    required Offset pivot,
    required Duration hotDuration,
  }) {
    final int index = _spec.indices[slot];
    final double angle = _angleOf(slot);
    final double p = _popProgress(slot);
    // 牌中心到支点的偏移（Transform 的 origin 以子组件中心为原点）。
    const Offset toPivot = Offset(0, _kArm - _kCardHeight / 2);
    return Positioned(
      key: ValueKey<int>(index),
      left: pivot.dx - _kCardWidth / 2,
      top: pivot.dy - _kArm,
      width: _kCardWidth,
      height: _kCardHeight,
      child: Transform.rotate(
        angle: lerpDouble(angle * 0.04, angle, p)!,
        origin: toPivot,
        child: Transform.translate(
          offset: Offset(0, lerpDouble(240, 0, p)!),
          child: Transform.scale(
            scale: lerpDouble(0.4, 1, p)!,
            origin: toPivot,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (PointerEnterEvent _) {
                if (!_dragMode && _open) _setHot(index);
              },
              onExit: (PointerExitEvent _) {
                if (!_dragMode && _hot == index) _setHot(null);
              },
              child: Semantics(
                button: true,
                selected: index == _spec.currentIndex,
                label: _spec.item(index).label,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: () => _play(index),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: index == _hot ? 1 : 0),
                    duration: hotDuration,
                    curve: FushiSpringCurve.spatial,
                    builder: (BuildContext context, double hot, Widget? _) =>
                        Transform.translate(
                          offset: Offset(0, -_kHotLift * hot),
                          child: Transform.scale(
                            scale: 1 + _kHotScale * hot,
                            child: _FanCard(
                              item: _spec.item(index),
                              hot: hot.clamp(0.0, 1.0),
                              current: index == _spec.currentIndex,
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 扇开后的一张牌：左上角图标（层叠时也露得出来），名字竖排在图标下方。
class _FanCard extends StatelessWidget {
  const _FanCard({
    required this.item,
    required this.hot,
    required this.current,
  });

  final AdaptiveNavItem item;

  /// 抽起程度 0..1（换色用）。
  final double hot;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = Color.lerp(
      scheme.surfaceContainerLowest,
      scheme.tertiary,
      hot,
    )!;
    final Color foreground = Color.lerp(
      scheme.onSurface,
      scheme.onTertiary,
      hot,
    )!;
    final Color border = current
        ? scheme.tertiary
        : Color.lerp(scheme.outlineVariant, scheme.tertiary, hot)!;
    final TextStyle labelStyle = context.fushiType.labelSmall.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.15,
      color: foreground.withValues(alpha: 0.85),
    );
    final String label = item.label;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(_kCardRadius),
        border: Border.all(color: border, width: current ? 3 : 1),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.25 + 0.1 * hot),
            blurRadius: 8 + 6 * hot,
            offset: Offset(-2, 2 + 2 * hot),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_kCardRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 7, 2, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiIcon(item.icon, size: 20, color: foreground),
              const SizedBox(height: 4),
              Expanded(child: _verticalLabel(label, labelStyle)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 竖排名字：中日韩文字逐字直立往下排，其余文字整行顺时针转 90°。
Widget _verticalLabel(String label, TextStyle style) {
  final bool cjk = label.runes.any((int r) => r >= 0x2E80);
  if (cjk) {
    return Text(
      label.characters.join('\n'),
      style: style,
      overflow: TextOverflow.clip,
      softWrap: false,
    );
  }
  return Align(
    alignment: Alignment.topLeft,
    child: RotatedBox(
      quarterTurns: 1,
      child: Text(
        label,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// 胶囊末格的小牌叠：三张小牌呈扇形微张，悬停 / 按下张得更开；当前页藏在
/// 扇里时最上面那张画当前项的小图标。
class _DeckGlyph extends StatelessWidget {
  const _DeckGlyph({required this.spread, required this.currentIcon});

  final bool spread;
  final IconData? currentIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Duration duration = fushiMotionDuration(
      context,
      const Duration(milliseconds: 350),
    );
    final double outer = spread ? 34 : 22;
    Widget card(double deg, Color color, {Widget? face}) {
      return AnimatedRotation(
        turns: deg / 360,
        duration: duration,
        curve: FushiSpringCurve.spatial,
        // 旋转支点在牌下方（CSS 的 50% 120%）。
        alignment: const Alignment(0, 1.4),
        child: Container(
          width: 18,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: face,
        ),
      );
    }

    return SizedBox(
      width: 34,
      height: 36,
      child: Stack(
        alignment: Alignment.topCenter,
        children: <Widget>[
          Positioned(
            top: 2,
            child: card(
              -outer,
              scheme.onTertiaryContainer.withValues(alpha: 0.45),
            ),
          ),
          Positioned(
            top: 2,
            child: card(0, scheme.onTertiaryContainer.withValues(alpha: 0.65)),
          ),
          Positioned(
            top: 2,
            child: card(
              outer,
              scheme.tertiary,
              face: currentIcon == null
                  ? null
                  : FushiIcon(currentIcon!, size: 13, color: scheme.onTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
