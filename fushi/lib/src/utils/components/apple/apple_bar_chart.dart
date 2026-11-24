/// Apple（Cupertino，iOS 27 / macOS 27）Swift Charts 式柱图：顶端圆角的 BarMark、
/// y 轴刻度在右侧、横向细网格，可选日均虚线 / 竖直规则线，点按 / 悬停弹注记。复习
/// 首页、游戏首页「本周」卡等 Apple 布局共用。
///
/// Apple 专用件：只在 `isGlassDesign` 为真时由 Apple 布局调用。本件只画内容层图形
/// （柱、网格、注记），不是系统控件，不分 M3E 分支；M3E 的柱图由各页自己的 MD3
/// 组件画。颜色一律取 Apple 系统色（`appleColorsOf`）。
///
/// 动效：入场柱从底部长出，时长取 [fushiMotionDuration]（减弱动效与墨水屏为 0）。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// 柱图的一根柱。
@immutable
class AppleChartBar {
  const AppleChartBar({
    required this.value,
    required this.title,
    this.label,
    this.color,
  });

  final int value;

  /// 点按 / 悬停时注记里的说明（「11/24 · 12 次复习」）。
  final String title;

  /// 横轴刻度；null = 这根不标。
  final String? label;

  /// 单柱颜色；null = 图表的 [AppleBarChart.color]。
  final Color? color;
}

/// Swift Charts 式柱图（拍板点 4）：顶端圆角的 BarMark、y 轴刻度在右侧、横向细网格；
/// 可选一条水平虚线 RuleMark（[average]，如「日均 27」）或一条竖直虚线 RuleMark
/// （[ruleAt]，0–1 的横向位置，如目标保留率「目标 90%」，注记在线顶）。入场柱从
/// 底部长出；点按 / 悬停一根柱在图顶弹出注记（Swift Charts 的 selection
/// annotation），再点同一根收起。
class AppleBarChart extends StatefulWidget {
  const AppleBarChart({
    super.key,
    required this.bars,
    required this.color,
    this.height = 96,
    this.average,
    this.averageLabel,
    this.ruleAt,
    this.ruleLabel,
    this.highlightLast = false,
    this.barWidthFactor = 0.56,
    this.edgeLabels = false,
    this.semanticLabel,
  });

  final List<AppleChartBar> bars;
  final Color color;
  final double height;

  /// 水平虚线的 y 值与注记。
  final double? average;
  final String? averageLabel;

  /// 竖直虚线的横向位置（0 = 第一根柱左缘，1 = 最后一根右缘）与线顶注记。
  final double? ruleAt;
  final String? ruleLabel;

  /// 只有最后一根（今天）实色，其余 55%。
  final bool highlightLast;

  /// 柱宽占格宽的比例。
  final double barWidthFactor;

  /// 刻度文字靠格左缘（直方图的区间起点），默认居中。
  final bool edgeLabels;

  /// 整张图的读屏摘要。
  final String? semanticLabel;

  @override
  State<AppleBarChart> createState() => _AppleBarChartState();
}

class _AppleBarChartState extends State<AppleBarChart> {
  int? _selected;

  /// y 轴右侧刻度区宽。
  static const double _axisWidth = 28;

  /// 底部刻度行高。
  static const double _tickHeight = 18;

  int? _indexAt(Offset local, double width) {
    final int n = widget.bars.length;
    if (n == 0) return null;
    final double plot = width - _axisWidth;
    if (local.dx < 0 || local.dx > plot) return null;
    return (local.dx / plot * n).floor().clamp(0, n - 1);
  }

  void _select(int? index, {bool toggle = false}) {
    final int? next = toggle && index == _selected ? null : index;
    if (next == _selected) return;
    setState(() => _selected = next);
  }

  @override
  void didUpdateWidget(AppleBarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int? s = _selected;
    if (s != null && s >= widget.bars.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextStyle tick =
        (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
          height: 1.1,
          letterSpacing: 0,
          color: apple.secondaryLabel,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    final TextStyle annotation = tick.copyWith(
      fontWeight: FontWeight.w600,
      color: apple.label,
    );
    final int? selected = _selected;
    final bool topRoom = widget.ruleAt != null && widget.ruleLabel != null;
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = box.maxWidth;
            final Widget chart = TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: fushiMotionDuration(context, FushiMotion.medium),
              curve: FushiMotion.enter,
              builder: (BuildContext context, double grow, Widget? _) =>
                  CustomPaint(
                    size: Size(width, widget.height),
                    painter: _AppleBarPainter(
                      bars: widget.bars,
                      color: widget.color,
                      grow: grow,
                      selected: selected,
                      highlightLast: widget.highlightLast,
                      barWidthFactor: widget.barWidthFactor,
                      edgeLabels: widget.edgeLabels,
                      average: widget.average,
                      averageLabel: widget.averageLabel,
                      ruleAt: widget.ruleAt,
                      ruleLabel: widget.ruleLabel,
                      topRoom: topRoom ? 16 : 6,
                      grid: apple.separator,
                      ruleColor: apple.label,
                      avgColor: apple.secondaryLabel,
                      tickStyle: tick,
                      annotationStyle: annotation,
                      textDirection: Directionality.of(context),
                      axisWidth: _axisWidth,
                      tickHeight: _tickHeight,
                    ),
                  ),
            );
            final Widget? callout = selected == null
                ? null
                : _callout(context, selected, width, annotation);
            return MouseRegion(
              onHover: (PointerHoverEvent e) =>
                  _select(_indexAt(e.localPosition, width)),
              onExit: (_) => _select(null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails d) =>
                    _select(_indexAt(d.localPosition, width), toggle: true),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[chart, ?callout],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _callout(
    BuildContext context,
    int index,
    double width,
    TextStyle style,
  ) {
    final FushiAppleColors apple = appleColorsOf(context);
    final int n = widget.bars.length;
    final double plot = width - _axisWidth;
    final double center = plot / n * (index + 0.5);
    // 注记贴在柱的正上方，左右夹在图内。
    final double x = width <= 0 ? 0 : (center / width).clamp(0.0, 1.0);
    final AppleChartBar bar = widget.bars[index];
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment(x * 2 - 1, -1),
          child: FractionalTranslation(
            translation: const Offset(0, -1.05),
            child: DecoratedBox(
              key: const ValueKey<String>('apple-bar-chart-callout'),
              decoration: ShapeDecoration(
                color: apple.tertiaryGroupedBackground,
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  bar.title,
                  maxLines: 1,
                  style: style,
                  semanticsLabel: bar.title,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「好看的」刻度步长：max / 3 取 1 / 2 / 5 × 10^k。
int _niceStep(int max) {
  if (max <= 3) return 1;
  final double raw = max / 3;
  final double m = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final double f = raw / m;
  final double step = (f <= 1 ? 1 : (f <= 2 ? 2 : (f <= 5 ? 5 : 10))) * m;
  return math.max(1, step.round());
}

class _AppleBarPainter extends CustomPainter {
  _AppleBarPainter({
    required this.bars,
    required this.color,
    required this.grow,
    required this.selected,
    required this.highlightLast,
    required this.barWidthFactor,
    required this.edgeLabels,
    required this.average,
    required this.averageLabel,
    required this.ruleAt,
    required this.ruleLabel,
    required this.topRoom,
    required this.grid,
    required this.ruleColor,
    required this.avgColor,
    required this.tickStyle,
    required this.annotationStyle,
    required this.textDirection,
    required this.axisWidth,
    required this.tickHeight,
  });

  final List<AppleChartBar> bars;
  final Color color;
  final double grow;
  final int? selected;
  final bool highlightLast;
  final double barWidthFactor;
  final bool edgeLabels;
  final double? average;
  final String? averageLabel;
  final double? ruleAt;
  final String? ruleLabel;
  final double topRoom;
  final Color grid;
  final Color ruleColor;
  final Color avgColor;
  final TextStyle tickStyle;
  final TextStyle annotationStyle;
  final TextDirection textDirection;
  final double axisWidth;
  final double tickHeight;

  void _text(
    Canvas canvas,
    String text,
    TextStyle style,
    Offset at, {
    double alignX = 0,
  }) {
    final TextPainter p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      maxLines: 1,
    )..layout();
    p.paint(canvas, at - Offset(p.width * alignX, 0));
    p.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final int n = bars.length;
    final double plotW = size.width - axisWidth;
    final double plotH = size.height - tickHeight - topRoom;
    if (n == 0 || plotW <= 0 || plotH <= 0) return;
    int top = 0;
    for (final AppleChartBar b in bars) {
      top = math.max(top, b.value);
    }
    final double avg = average ?? 0;
    top = math.max(top, avg.ceil());
    final int step = _niceStep(math.max(1, top));
    final int axisMax = math.max(step, (top / step).ceil() * step);
    double yOf(double v) => topRoom + plotH - plotH * v / axisMax;

    // 横向网格 + 右侧刻度。
    final Paint gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (int v = 0; v <= axisMax; v += step) {
      final double y = yOf(v.toDouble());
      canvas.drawLine(Offset(0, y), Offset(plotW, y), gridPaint);
      _text(canvas, '$v', tickStyle, Offset(plotW + 6, y - 6));
    }

    final double slot = plotW / n;
    final double barW = slot * barWidthFactor;
    final Radius radius = Radius.circular(math.min(4, barW / 2));
    for (int i = 0; i < n; i++) {
      final AppleChartBar b = bars[i];
      final double cx = slot * (i + 0.5);
      final double h = plotH * b.value / axisMax * grow;
      if (h > 0) {
        final Color base = b.color ?? color;
        final bool dim =
            (highlightLast && i != n - 1) ||
            (selected != null && selected != i);
        final Paint p = Paint()
          ..color = dim ? base.withValues(alpha: base.a * 0.55) : base;
        final Rect r = Rect.fromLTWH(
          cx - barW / 2,
          topRoom + plotH - h,
          barW,
          h,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(r, topLeft: radius, topRight: radius),
          p,
        );
      }
      final String? label = b.label;
      if (label != null) {
        _text(
          canvas,
          label,
          tickStyle,
          Offset(edgeLabels ? slot * i : cx, size.height - tickHeight + 4),
          alignX: edgeLabels ? 0 : 0.5,
        );
      }
    }

    final Paint dashed = Paint()..strokeWidth = 1.2;
    final double? avgValue = average;
    if (avgValue != null && avgValue > 0) {
      final double y = yOf(avgValue);
      dashed.color = avgColor;
      _dash(canvas, Offset(0, y), Offset(plotW, y), dashed);
      final String? text = averageLabel;
      if (text != null) {
        _text(
          canvas,
          text,
          annotationStyle.copyWith(color: avgColor),
          Offset(2, y - 14),
        );
      }
    }
    final double? at = ruleAt;
    if (at != null) {
      final double x = plotW * at.clamp(0.0, 1.0);
      dashed.color = ruleColor.withValues(alpha: 0.7);
      _dash(canvas, Offset(x, topRoom - 4), Offset(x, topRoom + plotH), dashed);
      final String? text = ruleLabel;
      if (text != null) {
        _text(
          canvas,
          text,
          annotationStyle,
          Offset(x - 4, 0),
          alignX: x > plotW / 2 ? 1 : 0,
        );
      }
    }
  }

  void _dash(Canvas canvas, Offset a, Offset b, Paint paint) {
    const double on = 4, off = 3;
    final double length = (b - a).distance;
    if (length <= 0) return;
    final Offset dir = (b - a) / length;
    double d = 0;
    while (d < length) {
      final double e = math.min(d + on, length);
      canvas.drawLine(a + dir * d, a + dir * e, paint);
      d = e + off;
    }
  }

  @override
  bool shouldRepaint(_AppleBarPainter old) =>
      old.grow != grow ||
      old.selected != selected ||
      old.bars != bars ||
      old.color != color ||
      old.average != average ||
      old.ruleAt != ruleAt ||
      old.grid != grid ||
      old.tickStyle != tickStyle;
}
