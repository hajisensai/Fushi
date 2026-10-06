import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';

// Material 3 Expressive（Google 2025-05，Android 16）的按钮动效：Flutter 3.44
// 核心库还没有 Expressive 组件，这里自己实现三样共享件——
//
// - [FushiPressMorph]：按压变形。保留 Material 按钮本体（行为 / 焦点 / 语义
//   不变），只把 `style.shape` 换成随弹簧插值的 [FushiMorphBorder]：静止全胶囊，
//   按下弹到小圆角，松手弹回；toggle 选中态常驻方圆角。
// - [FushiConnectedButtonGroup]：连接式按钮组（MD3 的 SegmentedButton）。段间
//   2px 缝、外端全圆角、内侧小圆角，选中段弹成全胶囊，按下的段变宽、邻段让出。
// - [FushiButtonGroup]：标准按钮组。一排按钮，按下的变宽、邻居被挤窄。
//
// 弹簧取 M3 Expressive 的 motion scheme：按压用「fast spatial」（刚度 1400、
// 阻尼比 0.9），选中形变用「default spatial」（刚度 700、阻尼比 0.9）。墨水屏与
// 系统「减少动画」下不做任何形变（保持原有胶囊），见 [fushiExpressiveMotionEnabled]。

/// M3 Expressive「fast spatial」弹簧：按压形变 / 宽度挤压。
final SpringDescription fushiExpressiveFastSpatial =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 1400, ratio: 0.9);

/// M3 Expressive「default spatial」弹簧：选中态形变（比按压慢半拍）。
final SpringDescription fushiExpressiveDefaultSpatial =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 700, ratio: 0.9);

/// 是否做 Expressive 形变动效：墨水屏（残影 + 刷新慢）与系统「减少动画」下
/// 一律不做——两者都要求界面静止，形变只是装饰，不承载信息。
bool fushiExpressiveMotionEnabled(BuildContext context) {
  if (isEinkTheme(context)) return false;
  return !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

/// M3 Expressive 图标按钮尺寸档：XS 32 / S 40（默认）/ M 56。
enum FushiIconButtonSize { xs, s, m }

/// M3 Expressive 图标按钮宽度变体：窄 / 默认（正方）/ 宽。
enum FushiIconButtonWidth { narrow, standard, wide }

/// M3 Expressive 图标按钮形状：圆（默认）/ 方（圆角 12）。
enum FushiIconButtonShape { round, square }

/// 图标按钮的容器尺寸（M3 Expressive 规格表：XS 28/32/40×32、S 32/40/52×40、
/// M 48/56/72×56，依次为窄 / 默认 / 宽）。
Size fushiExpressiveIconButtonExtent(
  FushiIconButtonSize size,
  FushiIconButtonWidth width,
) {
  final (
    double narrow,
    double standard,
    double wide,
    double height,
  ) = switch (size) {
    FushiIconButtonSize.xs => (28, 32, 40, 32),
    FushiIconButtonSize.s => (32, 40, 52, 40),
    FushiIconButtonSize.m => (48, 56, 72, 56),
  };
  return Size(switch (width) {
    FushiIconButtonWidth.narrow => narrow,
    FushiIconButtonWidth.standard => standard,
    FushiIconButtonWidth.wide => wide,
  }, height);
}

/// 图标按钮的图标尺寸：XS 20，S / M 24。
double fushiExpressiveIconSize(FushiIconButtonSize size) =>
    size == FushiIconButtonSize.xs ? 20 : 24;

/// 一个由弹簧驱动的标量（0 = 静止，1 = 目标态）。重定向时带着当前速度续上，
/// 快速连点不会「跳帧回零」——这是弹簧比定时曲线更顺的原因。
class FushiSpring {
  FushiSpring({
    required TickerProvider vsync,
    double initial = 0,
    SpringDescription? spring,
  }) : _controller = AnimationController.unbounded(
         vsync: vsync,
         value: initial,
       ),
       _target = initial,
       _spring = spring ?? fushiExpressiveFastSpatial;

  final AnimationController _controller;
  final SpringDescription _spring;
  double _target;

  Animation<double> get animation => _controller;
  double get value => _controller.value;
  double get target => _target;

  void animateTo(double target, {required bool animate}) {
    if (target == _target && (animate || _controller.value == target)) return;
    _target = target;
    if (!animate) {
      _controller.value = target;
      return;
    }
    _controller.animateWith(
      SpringSimulation(
        _spring,
        _controller.value,
        target,
        _controller.velocity,
      ),
    );
  }

  void dispose() => _controller.dispose();
}

/// 可在「固定圆角」与「全胶囊」之间连续插值的按钮外形。[startPill] /
/// [endPill] 分别控制起始侧 / 末尾侧两个角（横排 = 左 / 右，按文字方向翻转；
/// 竖排 = 上 / 下）：0 = [radius]，1 = 短边的一半（胶囊）。按实际尺寸解析，
/// 所以不需要预先知道按钮高度。
class FushiMorphBorder extends OutlinedBorder {
  const FushiMorphBorder({
    super.side,
    required this.radius,
    this.startPill = 1,
    this.endPill = 1,
    this.axis = Axis.horizontal,
  });

  final double radius;
  final double startPill;
  final double endPill;
  final Axis axis;

  RoundedRectangleBorder _resolve(Rect rect, TextDirection? textDirection) {
    final double half = rect.shortestSide / 2;
    Radius cornerFor(double pill) {
      final double t = pill.clamp(0.0, 1.0);
      final double r = (radius + (half - radius) * t).clamp(0.0, half);
      return Radius.circular(r);
    }

    final Radius start = cornerFor(startPill);
    final Radius end = cornerFor(endPill);
    final BorderRadius borderRadius;
    if (axis == Axis.vertical) {
      borderRadius = BorderRadius.vertical(top: start, bottom: end);
    } else {
      final bool rtl = textDirection == TextDirection.rtl;
      borderRadius = BorderRadius.horizontal(
        left: rtl ? end : start,
        right: rtl ? start : end,
      );
    }
    return RoundedRectangleBorder(side: side, borderRadius: borderRadius);
  }

  @override
  EdgeInsetsGeometry get dimensions =>
      RoundedRectangleBorder(side: side).dimensions;

  @override
  ShapeBorder scale(double t) => FushiMorphBorder(
    side: side.scale(t),
    radius: radius * t,
    startPill: startPill,
    endPill: endPill,
    axis: axis,
  );

  @override
  FushiMorphBorder copyWith({BorderSide? side}) => FushiMorphBorder(
    side: side ?? this.side,
    radius: radius,
    startPill: startPill,
    endPill: endPill,
    axis: axis,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is FushiMorphBorder && a.axis == axis) {
      return FushiMorphBorder(
        side: BorderSide.lerp(a.side, side, t),
        radius: lerpDouble(a.radius, radius, t)!,
        startPill: lerpDouble(a.startPill, startPill, t)!,
        endPill: lerpDouble(a.endPill, endPill, t)!,
        axis: axis,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is FushiMorphBorder && b.axis == axis) {
      return FushiMorphBorder(
        side: BorderSide.lerp(side, b.side, t),
        radius: lerpDouble(radius, b.radius, t)!,
        startPill: lerpDouble(startPill, b.startPill, t)!,
        endPill: lerpDouble(endPill, b.endPill, t)!,
        axis: axis,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _resolve(
    rect,
    textDirection,
  ).getInnerPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _resolve(
    rect,
    textDirection,
  ).getOuterPath(rect, textDirection: textDirection);

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) {
    _resolve(
      rect,
      textDirection,
    ).paintInterior(canvas, rect, paint, textDirection: textDirection);
  }

  @override
  bool get preferPaintInterior => true;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    _resolve(
      rect,
      textDirection,
    ).paint(canvas, rect, textDirection: textDirection);
  }

  @override
  bool operator ==(Object other) =>
      other is FushiMorphBorder &&
      other.side == side &&
      other.radius == radius &&
      other.startPill == startPill &&
      other.endPill == endPill &&
      other.axis == axis;

  @override
  int get hashCode => Object.hash(side, radius, startPill, endPill, axis);
}

/// [FushiPressMorph.builder] 的签名：拿到（可能已替换 shape 的）style 与应传给
/// Material 按钮的 statesController，构造原 Material 按钮。
typedef FushiPressMorphBuilder =
    Widget Function(
      BuildContext context,
      ButtonStyle? style,
      WidgetStatesController? statesController,
    );

/// M3 Expressive 按压变形包装：静止全胶囊（或 toggle 选中态的方圆角），按下
/// 弹簧过渡到 [pressedRadius]，松手弹回。
///
/// - 文字 / 填充 / 描边按钮经 `statesController` 读 [WidgetState.pressed]
///   （与 InkWell 高亮同一判据，滚动取消的按下不会变形）；调用方自带
///   controller 时监听它，否则自建一个。
/// - [IconButton] 不暴露 statesController，设 [trackPointer] 改用指针事件。
/// - 调用方 style 显式给了 shape 的不变形（尊重调用方）；墨水屏 / 减少动画
///   下原样构造。Material 的 shape 隐式动画被置零，避免与弹簧叠加出拖影。
class FushiPressMorph extends StatefulWidget {
  const FushiPressMorph({
    super.key,
    required this.enabled,
    required this.style,
    required this.builder,
    this.statesController,
    this.trackPointer = false,
    this.pressedRadius = 10,
    this.selected = false,
    this.selectedRadius = 14,
  });

  final bool enabled;
  final ButtonStyle? style;
  final WidgetStatesController? statesController;
  final bool trackPointer;
  final double pressedRadius;
  final bool selected;
  final double selectedRadius;
  final FushiPressMorphBuilder builder;

  @override
  State<FushiPressMorph> createState() => _FushiPressMorphState();
}

class _FushiPressMorphState extends State<FushiPressMorph>
    with TickerProviderStateMixin {
  late final FushiSpring _press = FushiSpring(vsync: this);
  late final FushiSpring _select = FushiSpring(
    vsync: this,
    initial: widget.selected ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );
  WidgetStatesController? _ownController;
  WidgetStatesController? _listened;
  bool _pressed = false;

  WidgetStatesController get _controller =>
      widget.statesController ?? (_ownController ??= WidgetStatesController());

  @override
  void initState() {
    super.initState();
    // 两个弹簧在 initState 里就建好：`late final` 懒初始化若首次访问发生在
    // dispose（从没按过 / 没切过选中），会在已停用的元素上 createTicker，
    // 查 TickerMode 祖先直接断言，卸载中途抛错还会把整棵树搞乱（切设计系统
    // 时的连环红屏）。
    _press;
    _select;
    _relisten();
  }

  void _relisten() {
    final WidgetStatesController? next = widget.trackPointer
        ? null
        : _controller;
    if (identical(next, _listened)) return;
    _listened?.removeListener(_onStates);
    _listened = next;
    _listened?.addListener(_onStates);
  }

  @override
  void didUpdateWidget(FushiPressMorph oldWidget) {
    super.didUpdateWidget(oldWidget);
    _relisten();
    if (oldWidget.selected != widget.selected) {
      _select.animateTo(
        widget.selected ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
    if (!widget.enabled) _setPressed(false);
  }

  void _onStates() {
    final WidgetStatesController? c = _listened;
    if (c == null) return;
    _setPressed(c.value.contains(WidgetState.pressed));
  }

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    _pressed = value;
    _press.animateTo(
      value ? 1 : 0,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  @override
  void dispose() {
    _listened?.removeListener(_onStates);
    _ownController?.dispose();
    _press.dispose();
    _select.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool morph =
        fushiExpressiveMotionEnabled(context) && widget.style?.shape == null;
    if (!morph) {
      return widget.builder(context, widget.style, widget.statesController);
    }
    final WidgetStatesController? controller = widget.trackPointer
        ? widget.statesController
        : _controller;
    Widget child = AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _press.animation,
        _select.animation,
      ]),
      builder: (BuildContext context, Widget? _) {
        final double p = _press.value.clamp(0.0, 1.0);
        final double s = _select.value.clamp(0.0, 1.0);
        final double pill = ((1 - s) * (1 - p)).clamp(0.0, 1.0);
        final double radius = lerpDouble(
          widget.selectedRadius,
          widget.pressedRadius,
          p,
        )!;
        final ButtonStyle style = (widget.style ?? const ButtonStyle())
            .copyWith(
              shape: WidgetStatePropertyAll<OutlinedBorder>(
                FushiMorphBorder(
                  radius: radius,
                  startPill: pill,
                  endPill: pill,
                ),
              ),
              animationDuration: Duration.zero,
            );
        return widget.builder(context, style, controller);
      },
    );
    if (widget.trackPointer) {
      child = Listener(
        onPointerDown: (_) {
          if (widget.enabled) _setPressed(true);
        },
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: child,
      );
    }
    return child;
  }
}

// ---------------------------------------------------------------------------
// 挤压排布：一排子项，按下的那个按比例变宽，宽度从相邻项匀出（总宽不变，
// 组的外框不抖）。连接式按钮组与标准按钮组共用。
// ---------------------------------------------------------------------------

class _FushiSqueezeParentData extends ContainerBoxParentData<RenderBox> {}

class _FushiSqueezeRow extends MultiChildRenderObjectWidget {
  const _FushiSqueezeRow({
    required this.press,
    required this.growFactor,
    required this.gap,
    required this.equalExtents,
    required this.expand,
    required super.children,
  });

  final List<double> press;
  final double growFactor;
  final double gap;
  final bool equalExtents;
  final bool expand;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFushiSqueeze(
    press: press,
    growFactor: growFactor,
    gap: gap,
    equalExtents: equalExtents,
    expand: expand,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFushiSqueeze renderObject,
  ) {
    renderObject
      ..press = press
      ..growFactor = growFactor
      ..gap = gap
      ..equalExtents = equalExtents
      ..expand = expand
      ..textDirection = Directionality.of(context);
  }
}

class _RenderFushiSqueeze extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FushiSqueezeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FushiSqueezeParentData> {
  _RenderFushiSqueeze({
    required List<double> press,
    required double growFactor,
    required double gap,
    required bool equalExtents,
    required bool expand,
    required TextDirection textDirection,
  }) : _press = press,
       _growFactor = growFactor,
       _gap = gap,
       _equalExtents = equalExtents,
       _expand = expand,
       _textDirection = textDirection;

  List<double> _press;
  set press(List<double> value) {
    if (listEquals(_press, value)) return;
    _press = value;
    markNeedsLayout();
  }

  double _growFactor;
  set growFactor(double value) {
    if (_growFactor == value) return;
    _growFactor = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  bool _equalExtents;
  set equalExtents(bool value) {
    if (_equalExtents == value) return;
    _equalExtents = value;
    markNeedsLayout();
  }

  bool _expand;
  set expand(bool value) {
    if (_expand == value) return;
    _expand = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FushiSqueezeParentData) {
      child.parentData = _FushiSqueezeParentData();
    }
  }

  List<RenderBox> get _children {
    final List<RenderBox> result = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      result.add(child);
      child = childAfter(child);
    }
    return result;
  }

  double _gaps(int n) => n > 1 ? _gap * (n - 1) : 0;

  double _intrinsicMain(double height, double Function(RenderBox) measure) {
    final List<RenderBox> children = _children;
    if (children.isEmpty) return 0;
    final List<double> sizes = children.map(measure).toList();
    final double content = _equalExtents
        ? sizes.reduce(math.max) * sizes.length
        : sizes.fold<double>(0, (double a, double b) => a + b);
    return content + _gaps(children.length);
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _intrinsicMain(height, (RenderBox c) => c.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _intrinsicMain(height, (RenderBox c) => c.getMaxIntrinsicWidth(height));

  double _intrinsicCross(double width, double Function(RenderBox, double) m) {
    final List<RenderBox> children = _children;
    if (children.isEmpty) return 0;
    final double each = width.isFinite
        ? math.max(0, (width - _gaps(children.length)) / children.length)
        : double.infinity;
    return children
        .map((RenderBox c) => m(c, each))
        .fold<double>(0, (double a, double b) => math.max(a, b));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicCross(
    width,
    (RenderBox c, double w) => c.getMinIntrinsicHeight(w),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicCross(
    width,
    (RenderBox c, double w) => c.getMaxIntrinsicHeight(w),
  );

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  /// 各子项的最终宽度：基准宽（等宽 = 最宽者；否则各自的最大固有宽，受约束
  /// 时按比例缩放 / 撑满），再按按下进度把宽度从邻居匀给按下的那个。
  List<double> _widths(BoxConstraints constraints, List<RenderBox> children) {
    final int n = children.length;
    final double gaps = _gaps(n);
    List<double> base = children
        .map((RenderBox c) => c.getMaxIntrinsicWidth(double.infinity))
        .toList();
    if (_equalExtents) {
      final double widest = base.reduce(math.max);
      base = List<double>.filled(n, widest);
    }
    final double content = base.fold<double>(0, (double a, double b) => a + b);
    double? targetContent;
    if (constraints.hasBoundedWidth &&
        (_expand || content + gaps > constraints.maxWidth)) {
      targetContent = math.max(0, constraints.maxWidth - gaps);
    } else if (content + gaps < constraints.minWidth) {
      targetContent = constraints.minWidth - gaps;
    }
    if (targetContent != null) {
      final double target = targetContent;
      base = content > 0
          ? base.map((double w) => w * target / content).toList()
          : List<double>.filled(n, target / n);
    }
    final List<double> widths = List<double>.of(base);
    for (int i = 0; i < n && i < _press.length; i++) {
      final double p = _press[i];
      if (p == 0) continue;
      final List<int> neighbours = <int>[
        if (i > 0) i - 1,
        if (i < n - 1) i + 1,
      ];
      if (neighbours.isEmpty) continue;
      final double grow = _growFactor * base[i] * p;
      widths[i] += grow;
      for (final int j in neighbours) {
        widths[j] -= grow / neighbours.length;
      }
    }
    return widths.map((double w) => math.max(0.0, w)).toList();
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final List<RenderBox> children = _children;
    if (children.isEmpty) return constraints.smallest;
    final List<double> widths = _widths(constraints, children);
    final List<Size> sizes = <Size>[];
    for (int i = 0; i < children.length; i++) {
      final BoxConstraints cc = BoxConstraints(
        minWidth: widths[i],
        maxWidth: widths[i],
        maxHeight: constraints.maxHeight,
      );
      sizes.add(
        dry ? children[i].getDryLayout(cc) : _layoutChild(children[i], cc),
      );
    }
    double height = sizes.fold<double>(
      0,
      (double a, Size s) => math.max(a, s.height),
    );
    height = math.max(height, constraints.minHeight);
    if (_equalExtents) {
      // 连接式按钮组的段必须等高（图标段与文字段的固有高可能差一两像素）。
      for (int i = 0; i < children.length; i++) {
        if (sizes[i].height == height) continue;
        final BoxConstraints cc = BoxConstraints.tightFor(
          width: widths[i],
          height: height,
        );
        sizes[i] = dry
            ? children[i].getDryLayout(cc)
            : _layoutChild(children[i], cc);
      }
    }
    final double width =
        widths.fold<double>(0, (double a, double b) => a + b) +
        _gaps(children.length);
    final Size size = constraints.constrain(Size(width, height));
    if (!dry) {
      double x = 0;
      final bool rtl = _textDirection == TextDirection.rtl;
      for (int i = 0; i < children.length; i++) {
        final _FushiSqueezeParentData data =
            children[i].parentData! as _FushiSqueezeParentData;
        final double dx = rtl ? size.width - x - sizes[i].width : x;
        data.offset = Offset(dx, (size.height - sizes[i].height) / 2);
        x += sizes[i].width + _gap;
      }
    }
    return size;
  }

  Size _layoutChild(RenderBox child, BoxConstraints constraints) {
    child.layout(constraints, parentUsesSize: true);
    return child.size;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}

// ---------------------------------------------------------------------------
// 连接式按钮组（MD3 的 SegmentedButton）
// ---------------------------------------------------------------------------

/// 内侧相邻角的圆角（M3 Expressive 连接式按钮组 40dp 档：8）。
const double _kConnectedInnerRadius = 8;

/// 段与段之间的缝。
const double _kConnectedGap = 2;

/// 前置图标 / 对勾与文字的间距。
const double _kConnectedIconGap = 8;

/// 按下的段变宽的比例（邻段各让出一半）。
const double _kConnectedGrow = 0.12;

/// M3 Expressive 连接式按钮组：[SegmentedButton] 的同参替身（多选 /
/// emptySelectionAllowed / 键盘焦点 / 语义 / tooltip 语义一致），每段是一个
/// 真 [TextButton]。
///
/// 形态：段间 2px 缝；组外侧两端全圆角，内侧相邻角 8；**选中段弹成全胶囊**
/// （default spatial 弹簧）并填 primary + onPrimary + 对勾（M3 Expressive
/// 连接式组用的是 filled toggle：选中 primary；secondaryContainer 与未选的
/// 底同为浅色，两段读成两颗互不相干的淡色胶囊），未选
/// surfaceContainerHighest + onSurface；高 40（紧凑密度 32）；各段等宽，宽度
/// 按「最宽标签 + 对勾槽」预留，对勾随选中弹簧从 0 展开，切换选中时整组
/// 总宽与其它段位置都不动；按下的段宽 +12%、
/// 相邻段让出（fast spatial 弹簧），松手复原。调用方 style 的颜色 / 字体 /
/// 内边距 / 密度照用，shape 与 side 由组决定（与 SegmentedButton 一样不下发到段）。
class FushiConnectedButtonGroup<T> extends StatefulWidget {
  const FushiConnectedButtonGroup({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.expandedInsets,
    this.style,
    this.showSelectedIcon = true,
    this.selectedIcon,
    this.direction = Axis.horizontal,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final void Function(Set<T>)? onSelectionChanged;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;
  final EdgeInsets? expandedInsets;
  final ButtonStyle? style;
  final bool showSelectedIcon;
  final Widget? selectedIcon;
  final Axis direction;

  @override
  State<FushiConnectedButtonGroup<T>> createState() =>
      _FushiConnectedButtonGroupState<T>();
}

class _FushiConnectedButtonGroupState<T>
    extends State<FushiConnectedButtonGroup<T>>
    with TickerProviderStateMixin {
  final List<FushiSpring> _press = <FushiSpring>[];
  final List<FushiSpring> _select = <FushiSpring>[];
  final List<WidgetStatesController> _controllers = <WidgetStatesController>[];
  final List<bool> _pressed = <bool>[];

  @override
  void initState() {
    super.initState();
    _syncSegments();
  }

  @override
  void didUpdateWidget(FushiConnectedButtonGroup<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSegments();
    final bool motion = fushiExpressiveMotionEnabled(context);
    for (int i = 0; i < widget.segments.length; i++) {
      final bool selected = widget.selected.contains(widget.segments[i].value);
      _select[i].animateTo(selected ? 1 : 0, animate: motion);
    }
  }

  /// 每段一组弹簧 / 状态控制器，按下标对齐（段数变化时增删尾部）。
  void _syncSegments() {
    final int n = widget.segments.length;
    while (_press.length < n) {
      final int i = _press.length;
      final bool selected = widget.selected.contains(widget.segments[i].value);
      _press.add(FushiSpring(vsync: this));
      _select.add(
        FushiSpring(
          vsync: this,
          initial: selected ? 1 : 0,
          spring: fushiExpressiveDefaultSpatial,
        ),
      );
      _pressed.add(false);
      final WidgetStatesController controller = WidgetStatesController();
      controller.addListener(() => _onStates(i));
      _controllers.add(controller);
    }
    while (_press.length > n) {
      _press.removeLast().dispose();
      _select.removeLast().dispose();
      _pressed.removeLast();
      _controllers.removeLast().dispose();
    }
  }

  void _onStates(int index) {
    if (!mounted || index >= _controllers.length) return;
    final bool pressed = _controllers[index].value.contains(
      WidgetState.pressed,
    );
    if (_pressed[index] == pressed) return;
    _pressed[index] = pressed;
    final bool motion = fushiExpressiveMotionEnabled(context);
    // 不做动效时不挤压（宽度保持静止），按下反馈只剩 Material 的状态层。
    _press[index].animateTo(pressed && motion ? 1 : 0, animate: motion);
  }

  @override
  void dispose() {
    for (final FushiSpring s in _press) {
      s.dispose();
    }
    for (final FushiSpring s in _select) {
      s.dispose();
    }
    for (final WidgetStatesController c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// 与 [SegmentedButtonState] 的按下逻辑同语义。
  void _handlePressed(T segmentValue) {
    final void Function(Set<T>)? notify = widget.onSelectionChanged;
    if (notify == null) return;
    final Set<T> current = widget.selected;
    final bool onlySelectedSegment =
        current.length == 1 && current.contains(segmentValue);
    final bool validChange =
        widget.emptySelectionAllowed || !onlySelectedSegment;
    if (!validChange) return;
    final bool toggle =
        widget.multiSelectionEnabled ||
        (widget.emptySelectionAllowed && onlySelectedSegment);
    final Set<T> pressed = <T>{segmentValue};
    final Set<T> updated = toggle
        ? (current.contains(segmentValue)
              ? current.difference(pressed)
              : current.union(pressed))
        : pressed;
    if (setEquals(updated, current)) return;
    notify(updated);
  }

  /// SegmentedButton 同款：只把段级字段下发到每段（shape / side 由组决定）。
  static ButtonStyle _segmentStyleFor(ButtonStyle? style) => ButtonStyle(
    textStyle: style?.textStyle,
    backgroundColor: style?.backgroundColor,
    foregroundColor: style?.foregroundColor,
    overlayColor: style?.overlayColor,
    surfaceTintColor: style?.surfaceTintColor,
    elevation: style?.elevation,
    padding: style?.padding,
    iconColor: style?.iconColor,
    iconSize: style?.iconSize,
    mouseCursor: style?.mouseCursor,
    visualDensity: style?.visualDensity,
    tapTargetSize: style?.tapTargetSize,
    animationDuration: style?.animationDuration,
    enableFeedback: style?.enableFeedback,
    alignment: style?.alignment,
    splashFactory: style?.splashFactory,
  );

  /// Expressive 段默认值：未选 onSurface、选中 onPrimary，
  /// 状态层取同色 8% / 10%。背景色由选中进度插值，见 build。
  static ButtonStyle _defaults(ThemeData theme) {
    final ColorScheme cs = theme.colorScheme;
    Color fg(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return cs.onSurface.withValues(alpha: 0.38);
      }
      return states.contains(WidgetState.selected)
          ? cs.onPrimary
          : cs.onSurface;
    }

    return ButtonStyle(
      textStyle: WidgetStatePropertyAll<TextStyle?>(theme.textTheme.labelLarge),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(fg),
      iconColor: WidgetStateProperty.resolveWith<Color?>(fg),
      overlayColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        final Color base = fg(states);
        if (states.contains(WidgetState.pressed)) {
          return base.withValues(alpha: 0.1);
        }
        if (states.contains(WidgetState.hovered)) {
          return base.withValues(alpha: 0.08);
        }
        if (states.contains(WidgetState.focused)) {
          return base.withValues(alpha: 0.1);
        }
        return null;
      }),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      elevation: const WidgetStatePropertyAll<double>(0),
      iconSize: const WidgetStatePropertyAll<double?>(18),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      minimumSize: const WidgetStatePropertyAll<Size?>(Size(40, 40)),
      side: const WidgetStatePropertyAll<BorderSide?>(BorderSide.none),
      alignment: Alignment.center,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Apple 设计系统：直接画 iOS 26 液态玻璃分段控件（[FushiSegmentedButton]
    // 的玻璃分支 = GlassSegmentedControl），不出现 MD3 连接式按钮组。
    if (isGlassDesign(context)) {
      return FushiSegmentedButton<T>(
        segments: widget.segments,
        selected: widget.selected,
        onSelectionChanged: widget.onSelectionChanged,
        multiSelectionEnabled: widget.multiSelectionEnabled,
        emptySelectionAllowed: widget.emptySelectionAllowed,
        expandedInsets: widget.expandedInsets,
        style: widget.style,
        showSelectedIcon: widget.showSelectedIcon,
        selectedIcon: widget.selectedIcon,
        direction: widget.direction,
      );
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final SegmentedButtonThemeData segTheme = SegmentedButtonTheme.of(context);
    final ButtonStyle callerStyle = _segmentStyleFor(widget.style);
    final ButtonStyle themeStyle = _segmentStyleFor(
      segTheme.style,
    ).merge(_defaults(theme));
    final bool customBackground =
        callerStyle.backgroundColor != null ||
        segTheme.style?.backgroundColor != null;
    final bool customPadding =
        callerStyle.padding != null || segTheme.style?.padding != null;
    final Widget? selectedIcon = widget.showSelectedIcon
        ? widget.selectedIcon ??
              segTheme.selectedIcon ??
              const Icon(Icons.check)
        : null;
    // 对勾槽的宽：按钮实际图标尺寸（调用方 / 主题 style 的 iconSize，缺省 18）。
    final double iconExtent =
        callerStyle.iconSize?.resolve(const <WidgetState>{}) ??
        themeStyle.iconSize?.resolve(const <WidgetState>{}) ??
        18;
    final bool enabled = widget.onSelectionChanged != null;
    final int n = widget.segments.length;
    final bool horizontal = widget.direction == Axis.horizontal;

    Widget segmentFor(int i) {
      final ButtonSegment<T> segment = widget.segments[i];
      final bool isSelected = widget.selected.contains(segment.value);
      final WidgetStatesController controller = _controllers[i];
      controller.update(WidgetState.selected, isSelected);
      final Widget label =
          segment.label ?? segment.icon ?? const SizedBox.shrink();
      // 段自带的前置图标（有文字时才作前置；纯图标段的图标就是 label）。
      final Widget? leadingIcon = segment.label != null ? segment.icon : null;
      final bool segmentEnabled = enabled && segment.enabled;
      final Widget button = AnimatedBuilder(
        animation: _select[i].animation,
        builder: (BuildContext context, Widget? _) {
          final double s = _select[i].value;
          final Widget content = selectedIcon == null
              ? (leadingIcon == null
                    ? label
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: _kConnectedIconGap,
                        children: <Widget>[
                          leadingIcon,
                          Flexible(child: label),
                        ],
                      ))
              : _ConnectedSegmentContent(
                  progress: s,
                  iconExtent: iconExtent,
                  selectedIcon: selectedIcon,
                  leadingIcon: leadingIcon,
                  label: label,
                );
          ButtonStyle style = callerStyle.copyWith(
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              FushiMorphBorder(
                radius: _kConnectedInnerRadius,
                startPill: i == 0 ? 1 : s,
                endPill: i == n - 1 ? 1 : s,
                axis: widget.direction,
              ),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            // 形状 / 底色都由弹簧逐帧给出，Material 的隐式补间会叠出拖影。
            animationDuration: Duration.zero,
          );
          if (!customBackground) {
            style = style.copyWith(
              backgroundColor: WidgetStatePropertyAll<Color?>(
                segmentEnabled
                    ? Color.lerp(
                        cs.surfaceContainerHighest,
                        cs.primary,
                        s.clamp(0.0, 1.0),
                      )
                    : cs.onSurface.withValues(alpha: 0.12),
              ),
            );
          }
          if (!customPadding && (selectedIcon != null || leadingIcon != null)) {
            // 有对勾槽 / 前置图标时左右各 12（M3 带图标按钮是 12 / 16；这里
            // 对勾槽在每段都预留，取对称 12 让未选段的文字仍在段正中）。
            style = style.copyWith(
              padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                EdgeInsets.symmetric(horizontal: 12),
              ),
            );
          }
          return TextButton(
            style: style,
            statesController: controller,
            onPressed: segmentEnabled
                ? () => _handlePressed(segment.value)
                : null,
            child: content,
          );
        },
      );
      final Widget withTooltip = segment.tooltip != null
          ? Tooltip(message: segment.tooltip, child: button)
          : button;
      return MergeSemantics(
        child: Semantics(
          selected: isSelected,
          inMutuallyExclusiveGroup: widget.multiSelectionEnabled ? null : true,
          child: withTooltip,
        ),
      );
    }

    final List<Widget> segments = <Widget>[
      for (int i = 0; i < n; i++) segmentFor(i),
    ];

    Widget group;
    if (horizontal) {
      group = AnimatedBuilder(
        animation: Listenable.merge(
          _press.map((FushiSpring s) => s.animation).toList(),
        ),
        builder: (BuildContext context, Widget? _) => _FushiSqueezeRow(
          press: _press.map((FushiSpring s) => s.value).toList(),
          growFactor: _kConnectedGrow,
          gap: _kConnectedGap,
          equalExtents: true,
          expand: widget.expandedInsets != null,
          children: segments,
        ),
      );
    } else {
      group = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: _kConnectedGap,
        children: segments,
      );
      if (widget.expandedInsets == null) group = IntrinsicWidth(child: group);
    }

    // 与 SegmentedButton 同口径的触控目标补白：padded 时把 40 高的组上下补到 48。
    final VisualDensity density =
        callerStyle.visualDensity ??
        segTheme.style?.visualDensity ??
        theme.visualDensity;
    final MaterialTapTargetSize tapTargetSize =
        callerStyle.tapTargetSize ??
        segTheme.style?.tapTargetSize ??
        theme.materialTapTargetSize;
    final double dy = density.baseSizeAdjustment.dy;
    final double tapPadding = switch (tapTargetSize) {
      MaterialTapTargetSize.shrinkWrap => 0.0,
      MaterialTapTargetSize.padded => math.max(
        0.0,
        kMinInteractiveDimension + dy - (40 + dy),
      ),
    };

    return TextButtonTheme(
      data: TextButtonThemeData(style: themeStyle),
      child: Padding(
        padding: widget.expandedInsets ?? EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: tapPadding / 2),
          child: group,
        ),
      ),
    );
  }
}

/// 连接式按钮组单段的内容：对勾槽 + 文字。
///
/// 宽度恒定不随选中变化——这是「切换选中时整组不跳宽」的关键：各段等宽取
/// 最宽段的固有宽，若对勾只出现在选中段，最宽者就随选中段而变（实测 2 段
/// 「已解锁 / 全部」选中前者 194.6、后者 166.4）。这里每段都按「对勾槽 +
/// 间距 + 文字」占位：未选时槽宽为 0、两侧各补一半空白让文字居中，选中时
/// 槽随 [progress]（选中弹簧）展开、空白同步收回，总宽不变，文字平滑右移。
///
/// 段自带前置图标（[leadingIcon]）时槽恒定满宽，对勾与该图标交叉淡入。
class _ConnectedSegmentContent extends StatelessWidget {
  const _ConnectedSegmentContent({
    required this.progress,
    required this.iconExtent,
    required this.selectedIcon,
    required this.leadingIcon,
    required this.label,
  });

  final double progress;
  final double iconExtent;
  final Widget selectedIcon;
  final Widget? leadingIcon;
  final Widget label;

  @override
  Widget build(BuildContext context) {
    final double p = progress.clamp(0.0, 1.0);
    final double slot = iconExtent + _kConnectedIconGap;
    Widget sized(Widget icon) => SizedBox(
      width: iconExtent,
      height: iconExtent,
      child: Center(child: icon),
    );
    final Widget? leading = leadingIcon;
    if (leading != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: _kConnectedIconGap,
        children: <Widget>[
          SizedBox(
            width: iconExtent,
            height: iconExtent,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                // 透明的那枚不建（别让未选段树里多出一个对勾图标）。
                if (p < 1) Opacity(opacity: 1 - p, child: sized(leading)),
                if (p > 0) Opacity(opacity: p, child: sized(selectedIcon)),
              ],
            ),
          ),
          Flexible(child: label),
        ],
      );
    }
    final double open = slot * p;
    final double side = (slot - open) / 2;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: side),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 槽恒在（宽 0 时什么都不画），选中切换不改子树结构。
          SizedBox(
            width: open,
            height: iconExtent,
            // 未选（宽 0）时不建对勾，树里只有选中段带对勾图标。
            child: p <= 0
                ? null
                : ClipRect(
                    child: OverflowBox(
                      minWidth: slot,
                      maxWidth: slot,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: _kConnectedIconGap,
                        ),
                        child: Opacity(
                          opacity: p,
                          child: Transform.scale(
                            scale: 0.6 + 0.4 * p,
                            child: sized(selectedIcon),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Flexible(child: label),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 标准按钮组
// ---------------------------------------------------------------------------

/// 一排并列按钮。MD3 下是 M3 Expressive 标准按钮组：按下的按钮变宽
/// （+[growFactor]），相邻按钮被挤窄让出同样的宽度（fast spatial 弹簧），
/// 子按钮本身（FushiFilledButton 等）再各自做按压变形；Apple 设计系统下就是
/// 间距 [spacing] 的普通 Row，不挤压。
///
/// [expanded] = 在有界宽度里按各自固有宽的比例撑满整行（对话框动作行）。
/// 按压由指针事件判定（不认识子组件的启用态：禁用按钮被按下也会挤一下）。
class FushiButtonGroup extends StatefulWidget {
  const FushiButtonGroup({
    super.key,
    required this.children,
    this.spacing = 8,
    this.expanded = false,
    this.growFactor = 0.15,
  });

  final List<Widget> children;
  final double spacing;
  final bool expanded;
  final double growFactor;

  @override
  State<FushiButtonGroup> createState() => _FushiButtonGroupState();
}

class _FushiButtonGroupState extends State<FushiButtonGroup>
    with TickerProviderStateMixin {
  final List<FushiSpring> _press = <FushiSpring>[];

  void _sync(int n) {
    while (_press.length < n) {
      _press.add(FushiSpring(vsync: this));
    }
    while (_press.length > n) {
      _press.removeLast().dispose();
    }
  }

  void _setPressed(int index, bool pressed) {
    if (index >= _press.length) return;
    if (!fushiExpressiveMotionEnabled(context)) return;
    _press[index].animateTo(pressed ? 1 : 0, animate: true);
  }

  @override
  void dispose() {
    for (final FushiSpring s in _press) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return Row(
        mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
        spacing: widget.spacing,
        children: widget.expanded
            ? <Widget>[
                for (final Widget child in widget.children)
                  Expanded(child: child),
              ]
            : widget.children,
      );
    }
    final int n = widget.children.length;
    _sync(n);
    final List<Widget> items = <Widget>[
      for (int i = 0; i < n; i++)
        Listener(
          onPointerDown: (_) => _setPressed(i, true),
          onPointerUp: (_) => _setPressed(i, false),
          onPointerCancel: (_) => _setPressed(i, false),
          child: widget.children[i],
        ),
    ];
    return AnimatedBuilder(
      animation: Listenable.merge(
        _press.map((FushiSpring s) => s.animation).toList(),
      ),
      builder: (BuildContext context, Widget? _) => _FushiSqueezeRow(
        press: _press.map((FushiSpring s) => s.value).toList(),
        growFactor: widget.growFactor,
        gap: widget.spacing,
        equalExtents: false,
        expand: widget.expanded,
        children: items,
      ),
    );
  }
}
