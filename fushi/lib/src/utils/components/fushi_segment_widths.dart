import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 分段选择器的段宽分配，全仓所有横排分段共用这一份（BUG-4166：只接了两条
/// 路径，其余路径仍各写一份「等宽后整体等比缩窄」）：
/// - MD3 胶囊分段 `FushiPillSegmentedButton`、MD3 / 墨水屏连接式按钮组
///   `FushiConnectedButtonGroup`、Apple 退回形态（多选 / 允许空选 / 富文本段）
///   都经 [FushiSegmentRow] 排布；
/// - Apple 分段 `FushiAppleSegmentedControl` 自绘滑块，直接调本函数。
///
/// 反馈 GaI5uPQEbF（睡眠定时「播完本曲」被截成「播完…」）：旧实现两套都是
/// 「各段等宽、取最宽段」，总宽放不下时**所有段等比缩窄**，于是最长的那段先被
/// 省略号截断，而短段（「关闭」「15 分钟」）里还空着大片留白。按下面的顺序退让，
/// 每一级都只在上一级放不下时才启用：
///
/// 1. **等宽**：每段 = 最宽段的自然宽（选中胶囊在段间切换时宽度不跳）。[fill]
///    为 true（宿主要求撑满）时等分 [available]。
/// 2. **按内容分宽**：总宽 = [available]，窄段先被抬到同一宽度（注水），
///    宽段保持自然宽——谁都不截断。
/// 3. **收内边距**：各段按比例收掉 [extra]（首选内边距超出最小内边距的那部分），
///    文字仍完整。
/// 4. **仍放不下**：只压最宽的段（削峰），短段保持完整；压窄的段由调用方决定
///    换行（MD3）或省略（Apple 固定高度）。
///
/// [content] 是每段在**最小**内边距下的自然宽，[extra] 是首选内边距额外多占的
/// 宽；两者同序同长。[available] 为无穷大时按第 1 级返回（无界宽宿主按内容取宽）。
List<double> fushiSegmentWidths({
  required List<double> content,
  required List<double> extra,
  required double available,
  bool fill = false,
}) {
  assert(content.length == extra.length);
  final int n = content.length;
  if (n == 0) return const <double>[];
  final List<double> natural = <double>[
    for (int i = 0; i < n; i++) content[i] + extra[i],
  ];
  final double widest = natural.reduce(math.max);
  if (!available.isFinite) return List<double>.filled(n, widest);
  if (widest * n <= available) {
    return List<double>.filled(n, fill ? available / n : widest);
  }
  final double naturalSum = natural.fold(0, (double a, double b) => a + b);
  if (naturalSum <= available) {
    final double floor = _raiseFloorTo(natural, available);
    return <double>[for (final double w in natural) math.max(w, floor)];
  }
  final double contentSum = content.fold(0, (double a, double b) => a + b);
  if (contentSum <= available) {
    final double extraSum = naturalSum - contentSum;
    final double t = extraSum <= 0 ? 0 : (available - contentSum) / extraSum;
    return <double>[for (int i = 0; i < n; i++) content[i] + extra[i] * t];
  }
  final double cap = _lowerCapTo(content, math.max(0, available));
  return <double>[for (final double w in content) math.min(w, cap)];
}

/// 求 `w` 使 `Σ max(values[i], w) == target`（要求 `target >= Σ values`）。
double _raiseFloorTo(List<double> values, double target) {
  final List<double> sorted = List<double>.of(values)..sort();
  final int n = sorted.length;
  // 最小的 k 段被抬到同一水位 w，其余保持原宽：w = (target − 其余之和) / k。
  double untouched = sorted.fold(0, (double a, double b) => a + b);
  for (int k = 1; k <= n; k++) {
    untouched -= sorted[k - 1];
    final double level = (target - untouched) / k;
    if (k == n || level <= sorted[k]) return math.max(level, sorted[k - 1]);
  }
  return sorted.last;
}

/// 求 `c` 使 `Σ min(values[i], c) == target`（要求 `target < Σ values`）。
double _lowerCapTo(List<double> values, double target) {
  final List<double> sorted = List<double>.of(values)..sort();
  double rest = target;
  for (int i = 0; i < sorted.length; i++) {
    final int remaining = sorted.length - i;
    final double level = rest / remaining;
    if (level <= sorted[i]) return level;
    rest -= sorted[i];
  }
  return sorted.last;
}

/// 一排横向分段：段宽由 [fushiSegmentWidths] 按可用宽度分配，段间缝 [gap]，
/// 行高取各段最高者、所有段钉成同高（某段折行时其它段一起长高）并竖直居中。
///
/// 全仓横排分段的唯一排布实现（BUG-4166）。别再在别处写「各段取最宽段、
/// 放不下整体等比缩窄」——那正是最长段先被截断的根因（守卫：
/// `test/build/segmented_button_m3e_guard_test.dart`）。
///
/// [extras] 与 children 同序：每段首选内边距超出最小内边距的那部分宽度（放不下
/// 时先收它，见 [fushiSegmentWidths] 第 3 级）。默认 children 的固有宽是**最小**
/// 内边距下的宽，[extras] 加在其上；[extrasInIntrinsic] 为 true 时 children 的
/// 固有宽已含 [extras]（段自己在被压窄时收掉这部分，例如连接式按钮组两侧的
/// 对勾槽），分宽时先减去。
///
/// [fill] = 有界宽时撑满整行（等宽能放下时等分）；否则按内容取宽，宿主给了
/// 最小宽（紧约束）且不够时撑满到最小宽。
class FushiSegmentRow extends MultiChildRenderObjectWidget {
  const FushiSegmentRow({
    super.key,
    this.extras = const <double>[],
    this.extrasInIntrinsic = false,
    this.gap = 0,
    this.fill = false,
    this.textDirection,
    required super.children,
  });

  final List<double> extras;
  final bool extrasInIntrinsic;
  final double gap;
  final bool fill;

  /// 缺省取 [Directionality.of]。
  final TextDirection? textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFushiSegmentRow(
        extras: extras,
        extrasInIntrinsic: extrasInIntrinsic,
        gap: gap,
        fill: fill,
        textDirection: textDirection ?? Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderFushiSegmentRow renderObject,
  ) {
    renderObject
      ..extras = extras
      ..extrasInIntrinsic = extrasInIntrinsic
      ..gap = gap
      ..fill = fill
      ..textDirection = textDirection ?? Directionality.of(context);
  }
}

class _FushiSegmentRowParentData extends ContainerBoxParentData<RenderBox> {}

/// [FushiSegmentRow] 的渲染对象（支持固有尺寸 / dry layout / RTL / 紧约束）。
class RenderFushiSegmentRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FushiSegmentRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FushiSegmentRowParentData> {
  RenderFushiSegmentRow({
    required List<double> extras,
    required bool extrasInIntrinsic,
    required double gap,
    required bool fill,
    required TextDirection textDirection,
  }) : _extras = extras,
       _extrasInIntrinsic = extrasInIntrinsic,
       _gap = gap,
       _fill = fill,
       _textDirection = textDirection;

  List<double> _extras;
  set extras(List<double> value) {
    if (listEquals(value, _extras)) return;
    _extras = value;
    markNeedsLayout();
  }

  bool _extrasInIntrinsic;
  set extrasInIntrinsic(bool value) {
    if (value == _extrasInIntrinsic) return;
    _extrasInIntrinsic = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  bool _fill;
  set fill(bool value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FushiSegmentRowParentData) {
      child.parentData = _FushiSegmentRowParentData();
    }
  }

  List<RenderBox> get _segments {
    final List<RenderBox> out = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  double _extraAt(int i) => i < _extras.length ? _extras[i] : 0;

  double _gaps(int n) => n > 1 ? _gap * (n - 1) : 0;

  static double _sum(List<double> values) =>
      values.fold(0, (double a, double b) => a + b);

  /// [total] 是整行（含段间缝）的可用宽。
  List<double> _widthsFor(
    List<RenderBox> segments,
    double total, {
    bool fill = false,
  }) {
    final List<double> content = <double>[];
    final List<double> extra = <double>[];
    for (int i = 0; i < segments.length; i++) {
      final double intrinsic = segments[i].getMaxIntrinsicWidth(
        double.infinity,
      );
      final double e = _extraAt(i);
      content.add(_extrasInIntrinsic ? math.max(0, intrinsic - e) : intrinsic);
      extra.add(_extrasInIntrinsic ? math.min(e, intrinsic) : e);
    }
    return fushiSegmentWidths(
      content: content,
      extra: extra,
      available: total.isFinite
          ? math.max(0, total - _gaps(segments.length))
          : total,
      fill: fill,
    );
  }

  List<double> _widthsForConstraints(
    List<RenderBox> segments,
    BoxConstraints constraints,
  ) {
    if (_fill && constraints.hasBoundedWidth) {
      return _widthsFor(segments, constraints.maxWidth, fill: true);
    }
    final List<double> natural = _widthsFor(segments, constraints.maxWidth);
    if (_sum(natural) + _gaps(segments.length) >= constraints.minWidth) {
      return natural;
    }
    return _widthsFor(segments, constraints.minWidth, fill: true);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final List<RenderBox> segments = _segments;
    double sum = _gaps(segments.length);
    for (final RenderBox c in segments) {
      sum += c.getMinIntrinsicWidth(height);
    }
    return sum;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final List<RenderBox> segments = _segments;
    return _sum(_widthsFor(segments, double.infinity)) + _gaps(segments.length);
  }

  double _intrinsicHeight(double width) {
    final List<RenderBox> segments = _segments;
    final List<double> widths = _widthsFor(segments, width);
    double h = 0;
    for (int i = 0; i < segments.length; i++) {
      h = math.max(h, segments[i].getMaxIntrinsicHeight(widths[i]));
    }
    return h;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  /// 段只钉宽、高度不限（段按内容取高；第二遍再钉成行高）。给上界高度会让
  /// 带 alignment 的段（胶囊分段的 AnimatedContainer）撑满宿主高度。
  BoxConstraints _segmentConstraints(double width) =>
      BoxConstraints.tightFor(width: width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final List<RenderBox> segments = _segments;
    if (segments.isEmpty) return constraints.smallest;
    final List<double> widths = _widthsForConstraints(segments, constraints);
    double h = 0;
    for (int i = 0; i < segments.length; i++) {
      h = math.max(
        h,
        segments[i].getDryLayout(_segmentConstraints(widths[i])).height,
      );
    }
    return constraints.constrain(
      Size(_sum(widths) + _gaps(segments.length), h),
    );
  }

  @override
  void performLayout() {
    final List<RenderBox> segments = _segments;
    if (segments.isEmpty) {
      size = constraints.smallest;
      return;
    }
    final List<double> widths = _widthsForConstraints(segments, constraints);
    double height = 0;
    for (int i = 0; i < segments.length; i++) {
      segments[i].layout(_segmentConstraints(widths[i]), parentUsesSize: true);
      height = math.max(height, segments[i].size.height);
    }
    height = constraints.constrainHeight(height);
    final double total = _sum(widths) + _gaps(segments.length);
    size = constraints.constrain(Size(total, height));
    final bool rtl = _textDirection == TextDirection.rtl;
    double x = 0;
    for (int i = 0; i < segments.length; i++) {
      final RenderBox child = segments[i];
      // 第二遍把所有段钉成同高（某段折行时其它段一起长高）。
      if (child.size.height != height) {
        child.layout(
          BoxConstraints.tightFor(width: widths[i], height: height),
          parentUsesSize: true,
        );
      }
      final _FushiSegmentRowParentData data =
          child.parentData! as _FushiSegmentRowParentData;
      final double dx = rtl ? size.width - x - child.size.width : x;
      data.offset = Offset(dx, (size.height - child.size.height) / 2);
      x += child.size.width + _gap;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
