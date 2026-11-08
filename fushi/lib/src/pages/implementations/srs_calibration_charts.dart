part of 'srs_stat_charts.dart';

/// 校准图与 UM+（复习统计页「模型校准」分区）。数学与筛选在 fushi_engine `srs_calibration.dart` /
/// native/fushi_fsrs `calibration.rs`；这里只画。画法对齐 Search Stats Extended（kuma3-anki-app 同款）：
///
/// - 校准图：横轴箱均预测、纵轴箱均实际，点 + 95% 自助法竖线，虚线是完美校准，底部淡柱是每箱复习数
///   （对数分箱的箱宽，与分箱规则同一个刻度），两个模型各占半个箱宽；
/// - UM+：横轴两模型的分歧（FSRS − RWKV），纵轴各自的平均误差（预测 − 实际），0 那条是虚线；点的面积与
///   淡柱都是这箱的复习数，少于 [kSrsUmPlusSmallBucket] 条的箱画虚线与淡点（显不显示由调用方决定）。
///
/// 与本库其余图同一套交互：悬停 / 点按整列出气泡，再点同一列收起；系列名写在气泡里，颜色不单独承载含义。

/// 一条校准线（系列名、颜色、数据）。
@immutable
class SrsCalibrationLine {
  const SrsCalibrationLine(this.label, this.color, this.series);

  final String label;
  final Color color;
  final SrsCalibrationSeries series;
}

const int _kCalibrationBins = 20;

/// 第 [i] 个校准箱在横轴上的左边界（`ln(i + 1) / ln(21)`，0..1）。
double _calibrationEdge(int i) =>
    math.log(i + 1) / math.log(_kCalibrationBins + 1);

String _pct(double v, [int digits = 0]) =>
    '${(v * 100).toStringAsFixed(digits)}%';

/// 虚线段（Canvas 没有原生虚线）。
void _dashedLine(
  Canvas canvas,
  Offset a,
  Offset b,
  Paint paint, {
  double dash = 4,
  double gap = 3,
}) {
  final double len = (b - a).distance;
  if (len == 0) return;
  final Offset dir = (b - a) / len;
  for (double s = 0; s < len; s += dash + gap) {
    canvas.drawLine(a + dir * s, a + dir * math.min(s + dash, len), paint);
  }
}

void _paintText(
  Canvas canvas,
  String text,
  Offset at,
  TextStyle style, {
  double alignX = 0,
}) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset(at.dx - tp.width * alignX, at.dy - tp.height / 2));
}

/// 校准图。
class SrsCalibrationChart extends StatefulWidget {
  const SrsCalibrationChart({
    required this.lines,
    required this.countLabel,
    required this.predictedLabel,
    required this.actualLabel,
    required this.intervalLabel,
    super.key,
    this.height = 260,
  });

  final List<SrsCalibrationLine> lines;

  /// 气泡里的「次数」「预测」「实际」与区间文案（`{lower}` / `{upper}` 已由调用方填好的函数）。
  final String countLabel;
  final String predictedLabel;
  final String actualLabel;
  final String Function(String lower, String upper) intervalLabel;
  final double height;

  @override
  State<SrsCalibrationChart> createState() => _SrsCalibrationChartState();
}

class _SrsCalibrationChartState extends State<SrsCalibrationChart> {
  int? _selected;

  List<String> _tooltip(int bin) {
    final List<String> out = <String>[];
    for (final SrsCalibrationLine l in widget.lines) {
      final SrsCalibrationBin? b = l.series.bins
          .where((SrsCalibrationBin b) => b.index == bin)
          .firstOrNull;
      if (b == null) continue;
      out.add(
        '${l.label}  ${widget.predictedLabel} ${_pct(b.predicted, 1)} · '
        '${widget.actualLabel} ${_pct(b.actual, 1)} · ${widget.countLabel} ${b.count}',
      );
      if (b.lower != null && b.upper != null) {
        out.add(
          '  ${widget.intervalLabel(_pct(b.lower!, 1), _pct(b.upper!, 1))}',
        );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = _axisStyle(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double left = 36;
    final int? sel = _selected;
    final List<String>? tip = sel == null ? null : _tooltip(sel);
    return Semantics(
      container: true,
      label: tip?.join(', '),
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = box.maxWidth;
            void pick(Offset p, {bool toggle = false}) {
              final double plot = width - left - 8;
              final double v = ((p.dx - left) / plot).clamp(0.0, 1.0);
              int bin = 0;
              while (bin < _kCalibrationBins - 1 &&
                  _calibrationEdge(bin + 1) <= v) {
                bin++;
              }
              final bool has = widget.lines.any(
                (SrsCalibrationLine l) =>
                    l.series.bins.any((SrsCalibrationBin b) => b.index == bin),
              );
              setState(
                () => _selected = !has || (toggle && bin == _selected)
                    ? null
                    : bin,
              );
            }

            return MouseRegion(
              onHover: (PointerHoverEvent e) => pick(e.localPosition),
              onExit: (_) => setState(() => _selected = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails d) =>
                    pick(d.localPosition, toggle: true),
                child: CustomPaint(
                  size: Size(width, widget.height),
                  painter: _SrsCalibrationPainter(
                    lines: widget.lines,
                    left: left,
                    labelStyle: style,
                    gridColor: scheme.onSurfaceVariant,
                    surface: scheme.surfaceContainerLow,
                    selected: sel,
                    tooltip: tip,
                    tooltipBackground: scheme.inverseSurface,
                    tooltipStyle: style.copyWith(
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SrsCalibrationPainter extends CustomPainter {
  _SrsCalibrationPainter({
    required this.lines,
    required this.left,
    required this.labelStyle,
    required this.gridColor,
    required this.surface,
    required this.selected,
    required this.tooltip,
    required this.tooltipBackground,
    required this.tooltipStyle,
  });

  final List<SrsCalibrationLine> lines;
  final double left;
  final TextStyle labelStyle;
  final Color gridColor;
  final Color surface;
  final int? selected;
  final List<String>? tooltip;
  final Color tooltipBackground;
  final TextStyle tooltipStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final double plotW = size.width - left - 8;
    final double plotH = size.height - _kBottomPadding;
    double x(double v) => left + v * plotW;
    double y(double v) => plotH - v * plotH;
    final Paint grid = Paint()
      ..color = gridColor.withValues(alpha: 0.14)
      ..strokeWidth = 1;
    for (int i = 0; i <= 5; i++) {
      final double v = i / 5;
      canvas.drawLine(Offset(x(v), 0), Offset(x(v), plotH), grid);
      canvas.drawLine(Offset(left, y(v)), Offset(x(1), y(v)), grid);
      _paintText(
        canvas,
        _pct(v),
        Offset(left - 4, y(v)),
        labelStyle,
        alignX: 1,
      );
      _paintText(
        canvas,
        _pct(v),
        Offset(x(v), plotH + _kBottomPadding / 2),
        labelStyle,
        alignX: i == 0 ? 0 : (i == 5 ? 1 : 0.5),
      );
    }
    // 每箱复习数：底部淡柱，最高到绘图区的 40%。
    int maxCount = 1;
    for (final SrsCalibrationLine l in lines) {
      for (final SrsCalibrationBin b in l.series.bins) {
        maxCount = math.max(maxCount, b.count);
      }
    }
    final int n = math.max(1, lines.length);
    for (int s = 0; s < lines.length; s++) {
      final Paint bar = Paint()..color = lines[s].color.withValues(alpha: 0.2);
      for (final SrsCalibrationBin b in lines[s].series.bins) {
        final double x0 = x(_calibrationEdge(b.index)) + 1;
        final double w = (x(_calibrationEdge(b.index + 1)) - x0 - 1) / n;
        final double h = b.count / maxCount * plotH * 0.4;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x0 + s * w, plotH - h, math.max(1, w - 1), h),
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          bar,
        );
      }
    }
    final int? sel = selected;
    if (sel != null) {
      canvas.drawRect(
        Rect.fromLTRB(
          x(_calibrationEdge(sel)),
          0,
          x(_calibrationEdge(sel + 1)),
          plotH,
        ),
        Paint()..color = gridColor.withValues(alpha: 0.08),
      );
    }
    _dashedLine(
      canvas,
      Offset(x(0), y(0)),
      Offset(x(1), y(1)),
      Paint()
        ..color = gridColor.withValues(alpha: 0.6)
        ..strokeWidth = 1.5,
      dash: 5,
      gap: 4,
    );
    for (final SrsCalibrationLine l in lines) {
      final List<SrsCalibrationBin> bins = l.series.bins;
      if (bins.isEmpty) continue;
      final Path path = Path()..moveTo(x(bins[0].predicted), y(bins[0].actual));
      for (int i = 1; i < bins.length; i++) {
        path.lineTo(x(bins[i].predicted), y(bins[i].actual));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = l.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
      final Paint whisker = Paint()
        ..color = l.color.withValues(alpha: 0.55)
        ..strokeWidth = 1.25;
      for (final SrsCalibrationBin b in bins) {
        final double px = x(b.predicted);
        if (b.lower != null && b.upper != null) {
          canvas.drawLine(
            Offset(px, y(b.lower!)),
            Offset(px, y(b.upper!)),
            whisker,
          );
        }
        canvas.drawCircle(Offset(px, y(b.actual)), 5, Paint()..color = surface);
        canvas.drawCircle(
          Offset(px, y(b.actual)),
          3.5,
          Paint()..color = l.color,
        );
      }
    }
    final List<String>? lines2 = tooltip;
    if (sel != null && lines2 != null && lines2.isNotEmpty) {
      _paintTooltip(
        canvas,
        size,
        Offset(
          (x(_calibrationEdge(sel)) + x(_calibrationEdge(sel + 1))) / 2,
          plotH * 0.3,
        ),
        lines2,
        tooltipStyle,
        tooltipBackground,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SrsCalibrationPainter old) =>
      !identical(lines, old.lines) ||
      left != old.left ||
      labelStyle != old.labelStyle ||
      gridColor != old.gridColor ||
      selected != old.selected ||
      !listEquals(tooltip, old.tooltip);
}

/// UM+ 图。[bins] 是要画的箱（调用方按「显示少于 200 条的箱」筛好），[total] 是全部配对复习数（点的面积按它算占比）。
class SrsUmPlusChart extends StatefulWidget {
  const SrsUmPlusChart({
    required this.bins,
    required this.total,
    required this.fsrs,
    required this.rwkv,
    required this.tooltipOf,
    super.key,
    this.height = 240,
  });

  final List<SrsUmPlusBin> bins;
  final int total;
  final SrsChartSeries fsrs;
  final SrsChartSeries rwkv;

  /// 一箱的气泡文字。
  final List<String> Function(SrsUmPlusBin bin) tooltipOf;
  final double height;

  @override
  State<SrsUmPlusChart> createState() => _SrsUmPlusChartState();
}

class _SrsUmPlusChartState extends State<SrsUmPlusChart> {
  int? _selected;

  @override
  void didUpdateWidget(SrsUmPlusChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null && _selected! >= widget.bins.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = _axisStyle(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double left = 40;
    final (double x0, double x1) = srsUmPlusDisagreementDomain(widget.bins);
    final int? sel = _selected;
    final List<String>? tip = sel == null
        ? null
        : widget.tooltipOf(widget.bins[sel]);
    return Semantics(
      container: true,
      label: tip?.join(', '),
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = box.maxWidth;
            void pick(Offset p, {bool toggle = false}) {
              if (widget.bins.isEmpty) return;
              final double plot = width - left - 8;
              final double v = x0 + (p.dx - left) / plot * (x1 - x0);
              int best = 0;
              for (int i = 1; i < widget.bins.length; i++) {
                if ((widget.bins[i].disagreement - v).abs() <
                    (widget.bins[best].disagreement - v).abs()) {
                  best = i;
                }
              }
              setState(
                () => _selected = toggle && best == _selected ? null : best,
              );
            }

            return MouseRegion(
              onHover: (PointerHoverEvent e) => pick(e.localPosition),
              onExit: (_) => setState(() => _selected = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails d) =>
                    pick(d.localPosition, toggle: true),
                onHorizontalDragUpdate: (DragUpdateDetails d) =>
                    pick(d.localPosition),
                child: CustomPaint(
                  size: Size(width, widget.height),
                  painter: _SrsUmPlusPainter(
                    bins: widget.bins,
                    total: widget.total,
                    fsrsColor: widget.fsrs.color,
                    rwkvColor: widget.rwkv.color,
                    left: left,
                    labelStyle: style,
                    gridColor: scheme.onSurfaceVariant,
                    surface: scheme.surfaceContainerLow,
                    selected: sel,
                    tooltip: tip,
                    tooltipBackground: scheme.inverseSurface,
                    tooltipStyle: style.copyWith(
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SrsUmPlusPainter extends CustomPainter {
  _SrsUmPlusPainter({
    required this.bins,
    required this.total,
    required this.fsrsColor,
    required this.rwkvColor,
    required this.left,
    required this.labelStyle,
    required this.gridColor,
    required this.surface,
    required this.selected,
    required this.tooltip,
    required this.tooltipBackground,
    required this.tooltipStyle,
  });

  final List<SrsUmPlusBin> bins;
  final int total;
  final Color fsrsColor;
  final Color rwkvColor;
  final double left;
  final TextStyle labelStyle;
  final Color gridColor;
  final Color surface;
  final int? selected;
  final List<String>? tooltip;
  final Color tooltipBackground;
  final TextStyle tooltipStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty) return;
    final (double x0, double x1) = srsUmPlusDisagreementDomain(bins);
    final (double y0, double y1) = srsUmPlusErrorDomain(bins);
    final double plotW = size.width - left - 8;
    final double plotH = size.height - _kBottomPadding;
    double x(double v) => left + (v - x0) / (x1 - x0) * plotW;
    double y(double v) => (y1 - v) / (y1 - y0) * plotH;
    String signed(double v) => '${v > 0 ? '+' : ''}${(v * 100).round()}%';
    final Paint grid = Paint()
      ..color = gridColor.withValues(alpha: 0.14)
      ..strokeWidth = 1;
    final int xs = (x0 * 10).round(), xe = (x1 * 10).round();
    final int stepX = math.max(1, ((xe - xs) / 6).ceil());
    for (int t = xs; t <= xe; t++) {
      canvas.drawLine(Offset(x(t / 10), 0), Offset(x(t / 10), plotH), grid);
      if ((t - xs) % stepX == 0) {
        _paintText(
          canvas,
          signed(t / 10),
          Offset(x(t / 10), plotH + _kBottomPadding / 2),
          labelStyle,
          alignX: t == xs ? 0 : (t == xe ? 1 : 0.5),
        );
      }
    }
    for (int t = (y0 * 10).round(); t <= (y1 * 10).round(); t++) {
      final Offset a = Offset(left, y(t / 10)),
          b = Offset(left + plotW, y(t / 10));
      if (t == 0) {
        _dashedLine(
          canvas,
          a,
          b,
          Paint()
            ..color = gridColor.withValues(alpha: 0.6)
            ..strokeWidth = 1.5,
          dash: 5,
          gap: 4,
        );
      } else {
        canvas.drawLine(a, b, grid);
      }
      _paintText(
        canvas,
        signed(t / 10),
        Offset(left - 4, y(t / 10)),
        labelStyle,
        alignX: 1,
      );
    }
    final int maxCount = bins.fold<int>(
      1,
      (int m, SrsUmPlusBin b) => math.max(m, b.count),
    );
    final double barW = math.max(2, plotW / ((x1 - x0) * 20) * 0.8);
    final Paint bar = Paint()..color = gridColor.withValues(alpha: 0.14);
    for (final SrsUmPlusBin b in bins) {
      final double h = b.count / maxCount * plotH * 0.35;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x(b.disagreement) - barW / 2, plotH - h, barW, h),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        bar,
      );
    }
    final int? sel = selected;
    if (sel != null) {
      final double cx = x(bins[sel].disagreement);
      canvas.drawLine(
        Offset(cx, 0),
        Offset(cx, plotH),
        Paint()
          ..color = gridColor.withValues(alpha: 0.4)
          ..strokeWidth = 1,
      );
    }
    bool small(SrsUmPlusBin b) => b.count < kSrsUmPlusSmallBucket;
    for (final (Color color, double Function(SrsUmPlusBin) value)
        in <(Color, double Function(SrsUmPlusBin))>[
          (fsrsColor, (SrsUmPlusBin b) => b.fsrsError),
          (rwkvColor, (SrsUmPlusBin b) => b.rwkvError),
        ]) {
      for (int i = 1; i < bins.length; i++) {
        final Offset a = Offset(
          x(bins[i - 1].disagreement),
          y(value(bins[i - 1])),
        );
        final Offset b = Offset(x(bins[i].disagreement), y(value(bins[i])));
        final bool dotted = small(bins[i - 1]) || small(bins[i]);
        final Paint p = Paint()
          ..color = color.withValues(alpha: dotted ? 0.55 : 1)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round;
        if (dotted) {
          _dashedLine(canvas, a, b, p, dash: 3, gap: 3);
        } else {
          canvas.drawLine(a, b, p);
        }
      }
      for (final SrsUmPlusBin b in bins) {
        final Offset c = Offset(x(b.disagreement), y(value(b)));
        final double r = math.max(
          3,
          math.sqrt(b.count / math.max(1, total)) * 22,
        );
        canvas.drawCircle(c, r + 1.5, Paint()..color = surface);
        canvas.drawCircle(
          c,
          r,
          Paint()..color = color.withValues(alpha: small(b) ? 0.45 : 0.9),
        );
      }
    }
    final List<String>? lines = tooltip;
    if (sel != null && lines != null) {
      _paintTooltip(
        canvas,
        size,
        Offset(x(bins[sel].disagreement), plotH * 0.25),
        lines,
        tooltipStyle,
        tooltipBackground,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SrsUmPlusPainter old) =>
      !identical(bins, old.bins) ||
      fsrsColor != old.fsrsColor ||
      rwkvColor != old.rwkvColor ||
      labelStyle != old.labelStyle ||
      gridColor != old.gridColor ||
      selected != old.selected ||
      !listEquals(tooltip, old.tooltip);
}
