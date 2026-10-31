import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/services.dart';
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
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;

/// 旋钮触发格的宽度（也是 [NavOverflowSpec.pinnedCount] 的 triggerWidth）。
const double _kKnobWidth = 56;

/// 按住旋钮横拖时，手指移动多少逻辑像素转过一格。
const double _kDragPxPerSlot = 48;

/// 横拖超过这个距离才算「拖」，否则松手算「轻点」（停在打开状态）。
const double _kDragSlop = 6;

/// 相邻两格的最大夹角（度）。目的地少时不摊满整圈，免得上半圈只露两三个。
const double _kMaxStepDeg = 36;

/// 转盘上目的地圆钮的直径（命中区 ≥ 48dp）。
const double _kDialItemSize = 52;

/// 底栏原型「拇指转盘」（[AdaptiveNavBarStyle] 同名值）。
///
/// 胶囊里先平铺放得下的固定目的地，最后一格是带刻度的旋钮：
/// - 按住旋钮：遮罩淡入，一面大半圆转盘从屏幕底部中线升起，全部目的地等角度
///   排在圆环上；左右拖 = 转盘跟手转动，松手吸附到最近一格并跳到指针对准的项。
/// - 轻点旋钮：转盘打开后停住，可在转盘上画圈转动、点图标直接跳转，点遮罩关闭。
/// - 键盘 / 手柄：Enter 打开，左右方向键转一格，Enter 跳转，Esc 关闭。
///
/// 转盘打开期间指针对准的项每换一次就轻震一次（按住旋钮横拖、画圈、方向键
/// 与吸附动画经过的每一格都算）。正对指针的项背后是它专属的 M3E 多边形
/// （[navShapeOf]），转动时由圆连续形变过去。
///
/// Apple 设计系统（2026-10-30）：同一套交互；盘面是 Apple 悬浮面的系统材质
/// 实色 + 发丝描边，对准项与旋钮中心是强调色实底圆、名字气泡是强调色胶囊，
/// 不画 M3E 多边形（见 [NavOverflowPalette]）。胶囊里的固定格由宿主的
/// [NavOverflowSpec.cellBuilder] 画（Apple 即标签栏同款 lens）。
///
/// [NavOverflowSpec.focusIdPrefix] 非空时旋钮登记成 `<前缀>-dial` 焦点目标，
/// 手柄方向键能从固定格走到它（Enter / A 打开转盘）。
class NavDialBar extends StatefulWidget {
  const NavDialBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavDialBar> createState() => _NavDialBarState();
}

class _NavDialBarState extends State<NavDialBar> with TickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final FocusNode _knobFocus = FocusNode(debugLabel: 'NavDialBar.knob');
  final FocusNode _dialFocus = FocusNode(debugLabel: 'NavDialBar.dial');

  /// 转盘旋转量，单位「格」：值为 k 时 `spec.indices[k]` 正对顶端指针。
  final ValueNotifier<double> _rotation = ValueNotifier<double>(0);

  late final AnimationController _open = AnimationController(vsync: this)
    ..addStatusListener(_onOpenStatus);
  late final CurvedAnimation _openCurve = CurvedAnimation(
    parent: _open,
    curve: FushiSpringCurve.spatial,
    reverseCurve: FushiMotion.exit,
  );
  late final AnimationController _snap = AnimationController(vsync: this)
    ..addListener(_onSnapTick);
  double _snapFrom = 0;
  double _snapTarget = 0;

  bool _isOpen = false;
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// 按住旋钮横拖中（转盘跟手、不插值）。
  bool _knobDragging = false;
  bool _knobMoved = false;
  double _dragStartX = 0;
  double _dragStartRotation = 0;

  /// 在转盘上画圈转动中。
  bool _dialPanning = false;
  double _panStartAngle = 0;
  double _panStartRotation = 0;

  /// 上一次发触觉时指针对准的格；转盘打开期间它一变就轻震一次。
  int _hapticSlot = 0;

  NavOverflowSpec get _spec => widget.spec;
  int get _count => _spec.indices.length;

  /// 相邻两格的夹角（度）。
  double get _stepDeg => _count <= 1 ? 0 : math.min(360 / _count, _kMaxStepDeg);

  /// 当前页在 [NavOverflowSpec.indices] 里的位置；当前页是 FAB 那一项时为 -1。
  int get _currentSlot => _spec.indices.indexOf(_spec.currentIndex);

  @override
  void initState() {
    super.initState();
    _rotation.value = math.max(_currentSlot, 0).toDouble();
    _hapticSlot = _topSlot(_rotation.value);
    _rotation.addListener(_onRotationChanged);
  }

  @override
  void didUpdateWidget(NavDialBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isOpen && _currentSlot >= 0) {
      _snap.stop();
      _rotation.value = _currentSlot.toDouble();
    }
  }

  @override
  void dispose() {
    _openCurve.dispose();
    _open.dispose();
    _snap.dispose();
    _rotation.dispose();
    _knobFocus.dispose();
    _dialFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 状态与动效

  /// 指针对准的格变了（转盘打开时）就轻震一次：每经过一个目的地都震。
  /// 关着时（外部切页把转盘复位）只同步、不震。
  void _onRotationChanged() {
    final int slot = _topSlot(_rotation.value);
    if (slot == _hapticSlot) return;
    _hapticSlot = slot;
    if (_isOpen && mounted) fushiSelectionHaptic(context);
  }

  /// 指针对准的那一格（`spec.indices` 里的位置）。
  int _topSlot(double rotation) {
    if (_count == 0) return 0;
    return rotation.round() % _count;
  }

  void _openDial({required bool requestFocus}) {
    if (_count == 0) return;
    _snap.stop();
    if (!_isOpen) {
      // 打开时从当前页开始（当前页是 FAB 那一项时沿用上次停的位置）。
      if (_currentSlot >= 0) {
        _rotation.value = _currentSlot.toDouble();
      } else {
        _rotation.value = _rotation.value.roundToDouble();
      }
      _hapticSlot = _topSlot(_rotation.value);
    }
    setState(() => _isOpen = true);
    _portal.show();
    if (fushiMotionEnabled(context)) {
      _open.duration = fushiMotionDuration(
        context,
        const Duration(milliseconds: 520),
      );
      _open.reverseDuration = fushiMotionDuration(
        context,
        const Duration(milliseconds: 220),
      );
      _open.forward();
    } else {
      _open.value = 1;
    }
    if (requestFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isOpen) _dialFocus.requestFocus();
      });
    }
  }

  void _closeDial() {
    if (!_isOpen) return;
    final bool hadFocus = _dialFocus.hasFocus;
    setState(() {
      _isOpen = false;
      _knobDragging = false;
      _dialPanning = false;
    });
    if (fushiMotionEnabled(context)) {
      _open.reverse();
    } else {
      _open.value = 0;
      _portal.hide();
    }
    if (hadFocus) _knobFocus.requestFocus();
  }

  void _onOpenStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !_isOpen) {
      _portal.hide();
    }
  }

  /// 弹簧吸附到 [target] 格（不跳转）。
  void _snapTo(double target) {
    if (!fushiMotionEnabled(context)) {
      _snap.stop();
      _rotation.value = target;
      return;
    }
    _snapFrom = _rotation.value;
    _snapTarget = target;
    _snap.duration = fushiMotionDuration(
      context,
      const Duration(milliseconds: 380),
    );
    _snap.forward(from: 0);
  }

  void _onSnapTick() {
    final double t = FushiSpringCurve.spatial.transform(_snap.value);
    _rotation.value = lerpDouble(_snapFrom, _snapTarget, t) ?? _snapTarget;
  }

  /// 跳到 `spec.indices[slot]` 并收起转盘。
  void _selectSlot(int slot) {
    if (_count == 0) return;
    final int index = _spec.indices[slot % _count];
    _closeDial();
    _spec.onSelect(index);
  }

  // ---------------------------------------------------------------------------
  // 旋钮手势：按住即开，横拖跟手，松手吸附 + 跳转；轻点则停在打开状态。

  void _onKnobDown(PointerDownEvent event) {
    if (_count == 0) return;
    _dragStartX = event.position.dx;
    _knobMoved = false;
    setState(() {
      _pressed = true;
      _knobDragging = true;
    });
    _openDial(requestFocus: false);
    _dragStartRotation = _rotation.value;
  }

  void _onKnobMove(PointerMoveEvent event) {
    if (!_knobDragging) return;
    final double dx = event.position.dx - _dragStartX;
    if (!_knobMoved && dx.abs() > _kDragSlop) _knobMoved = true;
    if (_knobMoved) {
      _rotation.value = _dragStartRotation + dx / _kDragPxPerSlot;
    }
  }

  void _onKnobUp(PointerUpEvent event) {
    if (!_knobDragging) return;
    final bool moved = _knobMoved;
    setState(() {
      _pressed = false;
      _knobDragging = false;
    });
    if (moved) {
      final int slot = _topSlot(_rotation.value);
      _snapTo(_rotation.value.roundToDouble());
      _selectSlot(slot);
    } else {
      // 轻点：转盘停住，键盘焦点交给转盘方便方向键继续转。
      _dialFocus.requestFocus();
    }
  }

  void _onKnobCancel(PointerCancelEvent event) {
    if (!_knobDragging) return;
    setState(() {
      _pressed = false;
      _knobDragging = false;
    });
    _snapTo(_rotation.value.roundToDouble());
    _closeDial();
  }

  // ---------------------------------------------------------------------------
  // 转盘上画圈转动（按角度）。

  /// [global] 相对转盘圆心的方位角（度，顶端为 0，顺时针为正）。
  double _angleAround(Offset global, Offset center) {
    final Offset v = global - center;
    return math.atan2(v.dx, -v.dy) * 180 / math.pi;
  }

  void _onDialPanStart(DragStartDetails details, Offset center) {
    _snap.stop();
    _panStartAngle = _angleAround(details.globalPosition, center);
    _panStartRotation = _rotation.value;
    setState(() => _dialPanning = true);
  }

  void _onDialPanUpdate(DragUpdateDetails details, Offset center) {
    if (!_dialPanning || _stepDeg == 0) return;
    double delta =
        _angleAround(details.globalPosition, center) - _panStartAngle;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    // 手指顺时针画圈 → 转盘顺时针转 → 左边那格转到顶端（格号减小）。
    _rotation.value = _panStartRotation - delta / _stepDeg;
  }

  void _onDialPanEnd() {
    if (!_dialPanning) return;
    setState(() => _dialPanning = false);
    _snapTo(_rotation.value.roundToDouble());
  }

  KeyEventResult _onDialKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.gameButtonB) {
      _closeDial();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _snapTo(_rotation.value.roundToDouble() - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _snapTo(_rotation.value.roundToDouble() + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _selectSlot(_topSlot(_snap.isAnimating ? _snapTarget : _rotation.value));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // 胶囊内

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return navOverflowPlainRow(_spec);
    final int pinned = _spec.pinnedCount(triggerWidth: _kKnobWidth);
    final double cellWidth = math.max(0, (_spec.width - _kKnobWidth) / pinned);
    return OverlayPortal.targetsRootOverlay(
      controller: _portal,
      overlayChildBuilder: _buildOverlay,
      child: Row(
        children: <Widget>[
          for (int k = 0; k < pinned; k++)
            Expanded(child: _spec.cellBuilder(_spec.indices[k], cellWidth)),
          SizedBox(
            width: _kKnobWidth,
            height: _spec.height,
            child: _buildKnob(context, pinned),
          ),
        ],
      ),
    );
  }

  Widget _buildKnob(BuildContext context, int pinned) {
    final NavOverflowPalette palette = NavOverflowPalette.of(context);
    final int slot = _currentSlot;
    // 当前页藏在转盘里（没平铺出来）时，旋钮中心换成当前项图标高亮。
    final AdaptiveNavItem? hiddenCurrent = slot >= pinned
        ? _spec.item(_spec.currentIndex)
        : null;
    final String tooltip =
        hiddenCurrent?.label ??
        MaterialLocalizations.of(context).showMenuTooltip;
    final double dotTurns = slot >= 0 && _count > 0 ? slot / _count : 0;

    final Widget knob = Semantics(
      button: true,
      label: tooltip,
      child: FushiTooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: FocusableActionDetector(
          focusNode: _knobFocus,
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (bool v) => setState(() => _hovered = v),
          onShowFocusHighlight: (bool v) => setState(() => _focused = v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (ActivateIntent intent) {
                _openDial(requestFocus: true);
                return null;
              },
            ),
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onKnobDown,
            onPointerMove: _onKnobMove,
            onPointerUp: _onKnobUp,
            onPointerCancel: _onKnobCancel,
            child: Center(
              child: ValueListenableBuilder<double>(
                valueListenable: _rotation,
                builder: (BuildContext context, double rotation, Widget? _) {
                  final double nudge = (_hovered || _pressed) ? 30 / 360 : 0;
                  final double follow = _isOpen
                      ? -rotation * _stepDeg / 360
                      : 0;
                  return AnimatedRotation(
                    turns: nudge + follow,
                    duration:
                        (_knobDragging || _dialPanning || _snap.isAnimating)
                        ? Duration.zero
                        : fushiMotionDuration(
                            context,
                            const Duration(milliseconds: 480),
                          ),
                    curve: FushiSpringCurve.spatial,
                    child: _KnobFace(
                      palette: palette,
                      dotTurns: dotTurns,
                      focused: _focused,
                      showDot: slot >= 0 && hiddenCurrent == null,
                      counterTurns: -(nudge + follow),
                      centerShape: hiddenCurrent == null || !palette.polygons
                          ? null
                          : navShapeOf(_spec.items, _spec.currentIndex),
                      center: hiddenCurrent == null
                          ? null
                          : FushiIcon(
                              hiddenCurrent.selectedIcon ?? hiddenCurrent.icon,
                              size: 16,
                              color: palette.onAccent,
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final FushiFocusId? focusId = _spec.dialFocusId;
    if (focusId == null) return knob;
    return FushiFocusRegistration(
      id: focusId,
      focusNode: _knobFocus,
      child: knob,
    );
  }

  // ---------------------------------------------------------------------------
  // 上层：遮罩 + 半圆转盘 + 指针 + 名字

  Widget _buildOverlay(BuildContext context) {
    final NavOverflowPalette palette = NavOverflowPalette.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double outerR = math.min(
      240,
      math.min(screen.width * 0.6, screen.height * 0.45),
    );
    final double ringR = outerR - 44;
    final Offset center = Offset(screen.width / 2, screen.height);

    return Positioned.fill(
      child: Focus(
        focusNode: _dialFocus,
        onKeyEvent: _onDialKey,
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_open, _rotation]),
          builder: (BuildContext context, Widget? _) {
            final double fade = _open.value.clamp(0.0, 1.0);
            final double rise = _openCurve.value;
            final double rotation = _rotation.value;
            final int top = _topSlot(rotation);
            final AdaptiveNavItem topItem = _spec.item(_spec.indices[top]);
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeDial,
                    child: ColoredBox(
                      color: palette.scrim.withValues(alpha: 0.36 * fade),
                    ),
                  ),
                ),
                Positioned(
                  left: center.dx - outerR,
                  top: center.dy - outerR,
                  width: outerR * 2,
                  height: outerR * 2,
                  child: IgnorePointer(
                    ignoring: !_isOpen,
                    child: Opacity(
                      opacity: fade,
                      child: Transform.translate(
                        offset: Offset(0, (1 - rise) * 120),
                        child: Transform.scale(
                          scale: lerpDouble(0.25, 1, rise) ?? 1,
                          child: _buildDial(
                            palette: palette,
                            outerR: outerR,
                            ringR: ringR,
                            center: center,
                            rotation: rotation,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: outerR + 14 + (1 - rise) * 40,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: fade,
                      child: Center(
                        child: _DialLabel(
                          key: ValueKey<int>(top),
                          label: topItem.label,
                          palette: palette,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildDial({
    required NavOverflowPalette palette,
    required double outerR,
    required double ringR,
    required Offset center,
    required double rotation,
  }) {
    final double step = _stepDeg;
    final List<Widget> items = <Widget>[];
    for (int k = 0; k < _count; k++) {
      double d = k - rotation;
      // 环绕到 [-n/2, n/2)：转出底部的格子从另一侧补上（底部在屏幕外，看不见跳变）。
      d = ((d + _count / 2) % _count) - _count / 2;
      final double angleDeg = d * step;
      if (angleDeg.abs() > 110) continue;
      final double a = angleDeg * math.pi / 180;
      final double proximity = step == 0
          ? 1
          : (1 - angleDeg.abs() / step).clamp(0.0, 1.0);
      final int index = _spec.indices[k];
      items.add(
        Positioned(
          left: outerR + math.sin(a) * ringR - _kDialItemSize / 2,
          top: outerR - math.cos(a) * ringR - _kDialItemSize / 2,
          width: _kDialItemSize,
          height: _kDialItemSize,
          child: _DialItem(
            item: _spec.item(index),
            shape: palette.polygons ? navShapeOf(_spec.items, index) : null,
            proximity: proximity,
            current: index == _spec.currentIndex,
            palette: palette,
            onTap: () => _selectSlot(k),
          ),
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: palette.shadow.withValues(alpha: 0.22),
                  blurRadius: 24,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
          ),
        ),
        // ClipOval 同时裁掉方形外角的命中区，点到角上算点遮罩。
        Positioned.fill(
          child: ClipOval(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (DragStartDetails d) => _onDialPanStart(d, center),
              onPanUpdate: (DragUpdateDetails d) => _onDialPanUpdate(d, center),
              onPanEnd: (DragEndDetails d) => _onDialPanEnd(),
              onPanCancel: _onDialPanEnd,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DialPlatePainter(
                        plate: palette.plate,
                        edge: palette.plateEdge,
                        tick: palette.content,
                        ringR: ringR,
                        tickTurns: -rotation * step / 360,
                      ),
                    ),
                  ),
                  ...items,
                ],
              ),
            ),
          ),
        ),
        // 顶端指针：MD3 菱形；Apple 一枚强调色圆点。
        Positioned(
          left: outerR - 7,
          top: 3,
          child: Transform.rotate(
            angle: palette.apple ? 0 : math.pi / 4,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: palette.accent,
                borderRadius: BorderRadius.circular(palette.apple ? 7 : 3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 胶囊里的小旋钮：刻度圆环 + 指示点（+ 当前页藏在转盘里时的中心高亮）。
class _KnobFace extends StatelessWidget {
  const _KnobFace({
    required this.palette,
    required this.dotTurns,
    required this.focused,
    required this.showDot,
    required this.counterTurns,
    this.center,
    this.centerShape,
  });

  final NavOverflowPalette palette;

  /// 指示点所在方位（圈），对应当前页在转盘上的位置。
  final double dotTurns;
  final bool focused;
  final bool showDot;

  /// 外层旋转量的反向，让中心图标保持正立。
  final double counterTurns;
  final Widget? center;

  /// 中心高亮的形状：当前项的专属多边形（与侧栏、底栏同一套）；null = 圆
  /// （Apple）。
  final RoundedPolygon? centerShape;

  @override
  Widget build(BuildContext context) {
    final Widget? centerGlyph = center;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _KnobTicksPainter(
                color: palette.content,
                focusColor: focused ? palette.accent : null,
              ),
            ),
          ),
          if (showDot)
            Positioned.fill(
              child: Transform.rotate(
                angle: dotTurns * 2 * math.pi,
                child: Align(
                  alignment: const Alignment(0, -0.78),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          if (centerGlyph != null)
            Transform.rotate(
              angle: counterTurns * 2 * math.pi,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: palette.accent,
                  shape: centerShape == null
                      ? const CircleBorder()
                      : MaterialShapeBorder(shape: centerShape!),
                ),
                child: centerGlyph,
              ),
            ),
        ],
      ),
    );
  }
}

class _KnobTicksPainter extends CustomPainter {
  const _KnobTicksPainter({required this.color, this.focusColor});

  final Color color;
  final Color? focusColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    final Paint tick = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    const int ticks = 12;
    for (int i = 0; i < ticks; i++) {
      final double a = i * 2 * math.pi / ticks;
      final Offset dir = Offset(math.sin(a), -math.cos(a));
      final double inner = i % 3 == 0 ? r - 9 : r - 6;
      canvas.drawLine(c + dir * inner, c + dir * (r - 2), tick);
    }
    final Paint ring = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(c, r - 11, ring);
    final Color? focus = focusColor;
    if (focus != null) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = focus
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_KnobTicksPainter old) =>
      old.color != color || old.focusColor != focusColor;
}

/// 转盘面：外圈环带（放目的地）+ 中心毂，环带外沿一圈随转盘转动的细刻度。
class _DialPlatePainter extends CustomPainter {
  const _DialPlatePainter({
    required this.plate,
    required this.edge,
    required this.tick,
    required this.ringR,
    required this.tickTurns,
  });

  final Color plate;

  /// 盘面外沿的发丝描边（Apple 悬浮面同款；MD3 为 null 不画）。
  final Color? edge;
  final Color tick;
  final double ringR;
  final double tickTurns;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double outerR = size.shortestSide / 2;
    final double bandInner = ringR - 38;
    final double hubR = math.max(0, bandInner - 20);

    final Paint fill = Paint()..color = plate;
    final Path band = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: outerR))
      ..addOval(Rect.fromCircle(center: c, radius: bandInner));
    canvas.drawPath(band, fill);
    canvas.drawCircle(c, hubR, Paint()..color = plate.withValues(alpha: 0.86));
    final Color? edgeColor = edge;
    if (edgeColor != null) {
      canvas.drawCircle(
        c,
        outerR - 0.25,
        Paint()
          ..color = edgeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5,
      );
    }

    final Paint tickPaint = Paint()
      ..color = tick.withValues(alpha: 0.35)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    const int ticks = 72;
    final double base = tickTurns * 2 * math.pi;
    for (int i = 0; i < ticks; i++) {
      final double a = base + i * 2 * math.pi / ticks;
      final Offset dir = Offset(math.sin(a), -math.cos(a));
      final double len = i % 6 == 0 ? 9 : 5;
      canvas.drawLine(
        c + dir * (outerR - 6 - len),
        c + dir * (outerR - 6),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_DialPlatePainter old) =>
      old.plate != plate ||
      old.edge != edge ||
      old.tick != tick ||
      old.ringR != ringR ||
      old.tickTurns != tickTurns;
}

/// 转盘上的一个目的地：越靠近指针越大、越接近选中色与专属多边形。
class _DialItem extends StatelessWidget {
  const _DialItem({
    required this.item,
    required this.shape,
    required this.proximity,
    required this.current,
    required this.palette,
    required this.onTap,
  });

  final AdaptiveNavItem item;

  /// 该项的专属多边形：正对指针时背后画成它，离开时连续形变回圆。null =
  /// 恒为圆（Apple）。
  final RoundedPolygon? shape;

  /// 0 = 离指针一格以上，1 = 正对指针。
  final double proximity;
  final bool current;
  final NavOverflowPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double p = FushiMotion.enter.transform(proximity);
    final Color accent = palette.accent;
    final Color bg =
        Color.lerp(
          current
              ? accent.withValues(alpha: 0.18)
              : accent.withValues(alpha: 0),
          accent,
          p,
        ) ??
        accent;
    final Color fg =
        Color.lerp(palette.content, palette.onAccent, p) ?? palette.onAccent;
    // 离指针越近越接近专属多边形（官方 MaterialShapeBorder 插值，转动即形变）；
    // Apple 恒为圆。
    final RoundedPolygon? polygon = shape;
    final ShapeBorder border = polygon == null
        ? const CircleBorder()
        : OutlinedBorder.lerp(
            MaterialShapeBorder(shape: MaterialShapes.circle),
            MaterialShapeBorder(shape: polygon),
            p.clamp(0.0, 1.0),
          )!;
    return Semantics(
      button: true,
      selected: current,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Transform.scale(
          scale: 1 + 0.25 * p,
          child: DecoratedBox(
            decoration: ShapeDecoration(color: bg, shape: border),
            child: Center(
              child: FushiIcon(
                (current || p > 0.5)
                    ? (item.selectedIcon ?? item.icon)
                    : item.icon,
                size: 24,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 转盘上方显示指针对准项的名字；换项时淡入 + 轻微上浮。
class _DialLabel extends StatelessWidget {
  const _DialLabel({super.key, required this.label, required this.palette});

  final String label;
  final NavOverflowPalette palette;

  @override
  Widget build(BuildContext context) {
    final TextStyle style =
        (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
          color: palette.onAccent,
          fontWeight: palette.apple ? FontWeight.w600 : FontWeight.w700,
        );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, const Duration(milliseconds: 200)),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double t, Widget? child) => Opacity(
        opacity: fushiMotionEnabled(context) ? t : 1,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 6),
          child: child,
        ),
      ),
      child: DecoratedBox(
        // MD3 卡片圆角；Apple 胶囊（iOS 的 HUD 标签）。
        decoration: ShapeDecoration(
          color: palette.accent,
          shape: palette.apple
              ? const StadiumBorder()
              : RoundedRectangleBorder(borderRadius: FushiM3eShape.cardRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(label, style: style),
        ),
      ),
    );
  }
}
