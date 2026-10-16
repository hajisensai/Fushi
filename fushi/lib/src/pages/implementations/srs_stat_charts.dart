import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/utils.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:fushi_srs/fushi_srs.dart' show srsDayToDate;

/// 复习统计（统计中心「复习」分区）的图表件：可点按 / 悬停看数值的柱状图与折线
/// 图、环形图、日历热力图、百分比堆叠条与图例。
///
/// 与统计中心其余图表同一套自绘方式（[CustomPainter]）与同一套刻度 / 横轴标签
/// 排布（[StatAxisScale]、[statXAxisLabelSlots]），不引第三方图表库。配色只问角色
/// （[SrsStatColors]，由 [StatChartColors] 与 [ColorScheme] 派生），深浅色与两套
/// 设计系统自动跟随主题。
///
/// 交互约定（dataviz）：柱 / 点的命中区是整列（比柱子宽），点按或悬停显示该列
/// 的明细气泡，再点同一列或移出收起；颜色不单独承载含义——气泡逐行写系列名，
/// 多系列的图下面恒有图例。

/// 复习统计的配色角色。
@immutable
class SrsStatColors {
  const SrsStatColors({
    required this.newCard,
    required this.learn,
    required this.young,
    required this.mature,
    required this.relearn,
    required this.filtered,
    required this.suspended,
    required this.buried,
    required this.again,
    required this.hard,
    required this.good,
    required this.easy,
    required this.accent,
    required this.empty,
    required this.ink,
    required this.surface,
  });

  /// 从当前主题派生（不写死色值）：
  ///
  /// - MD3：以主题主色的色相为锚，在 HCT 色环上转出各类别的色相（与
  ///   「存储占用」饼图同一做法）。同一主题种子派生的 primary / secondary /
  ///   tertiary 彩度低、色相相近（dataviz 校验器实测相邻 ΔE 只有 5，正常视力都
  ///   分不清），堆叠六类时不可用，所以只借主色色相、彩度与明度按深浅色各取一档。
  ///   成熟度是有序的：年轻 → 成熟 = 主色色相由浅到深；重学 / 重来恒用错误色；
  ///   暂停 / 搁置 / 筛选是中性色。
  /// - Apple：沿用 [StatChartColors.apple] 的系统色（强调色 / 橙 / 青 / 红）。
  /// - 墨水屏：只用明度区分（灰阶）。
  factory SrsStatColors.of(BuildContext context) {
    final StatChartColors c = statChartColorsOf(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color surface = scheme.surfaceContainerLow;
    final Color empty = statHeatmapEmptyColors(context).$1;
    final bool dark = scheme.brightness == Brightness.dark;
    if (isEinkTheme(context)) {
      Color grey(double t) => Color.lerp(scheme.onSurface, surface, t)!;
      return SrsStatColors(
        newCard: grey(0.55),
        learn: grey(0.35),
        young: grey(0.7),
        mature: grey(0),
        relearn: grey(0.2),
        filtered: grey(0.85),
        suspended: grey(0.8),
        buried: grey(0.9),
        again: grey(0),
        hard: grey(0.3),
        good: grey(0.55),
        easy: grey(0.8),
        accent: grey(0.1),
        empty: empty,
        ink: scheme.onSurfaceVariant,
        surface: surface,
      );
    }
    if (isGlassDesign(context)) {
      return SrsStatColors(
        newCard: c.third,
        learn: c.compare,
        young: Color.lerp(c.series, surface, 0.5)!,
        mature: c.series,
        relearn: c.down,
        filtered: c.neutral,
        suspended: Color.lerp(scheme.onSurfaceVariant, surface, 0.45)!,
        buried: c.neutral,
        again: c.down,
        hard: c.compare,
        good: c.up,
        easy: c.third,
        accent: c.series,
        empty: empty,
        ink: scheme.onSurfaceVariant,
        surface: surface,
      );
    }
    final double h = Hct.fromInt(scheme.primary.toARGB32()).hue;
    final double errorHue = Hct.fromInt(scheme.error.toARGB32()).hue;
    // 学习 / 新卡的色相：离主色与错误色都最远的两个（主题换色相时自动避开撞色，
    // 例如青色主题下不会把「学习」转到与「重学」相邻的橙红）。
    final double learnHue = srsFarthestHue(<double>[h, errorHue]);
    final double newHue = srsFarthestHue(<double>[h, errorHue, learnHue]);
    Color hct(double hue, double chroma, double light, double darkTone) =>
        Color(Hct.from(hue % 360, chroma, dark ? darkTone : light).toInt());
    // 明度也错开（红绿色弱靠明度分辨）：成熟深 / 年轻浅、重学与学习一深一浅；
    // 深色模式整体反过来，离深色卡底近的是「次要」。
    final Color mature = hct(h, 56, 38, 70);
    final Color err = hct(errorHue, 70, 46, 62);
    final Color learn = hct(learnHue, 56, 66, 76);
    final Color fresh = hct(newHue, 48, 52, 56);
    return SrsStatColors(
      newCard: fresh,
      learn: learn,
      young: hct(h, 44, 72, 46),
      mature: mature,
      relearn: err,
      filtered: hct(h, 6, 82, 34),
      suspended: hct(h, 6, 60, 60),
      buried: hct(h, 10, 76, 40),
      again: err,
      hard: learn,
      good: mature,
      easy: fresh,
      accent: mature,
      empty: empty,
      ink: scheme.onSurfaceVariant,
      surface: surface,
    );
  }

  final Color newCard;
  final Color learn;
  final Color young;
  final Color mature;
  final Color relearn;
  final Color filtered;
  final Color suspended;
  final Color buried;
  final Color again;
  final Color hard;
  final Color good;
  final Color easy;

  /// 单系列图（添加 / 按小时 / 分布）的颜色。
  final Color accent;

  /// 热力图空格。
  final Color empty;
  final Color ink;
  final Color surface;

  /// 评分 1..4 的颜色。
  List<Color> get ratings => <Color>[again, hard, good, easy];

  /// 热力图第 [level] 档（1..4）：主色由浅到深（单色相顺序色阶）。
  Color heat(int level) => Color.lerp(
    empty,
    accent,
    const <double>[0, 0.3, 0.55, 0.78, 1][level.clamp(0, 4)],
  )!;
}

/// 一个系列（图例项）。
@immutable
class SrsChartSeries {
  const SrsChartSeries(this.label, this.color);

  final String label;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is SrsChartSeries && other.label == label && other.color == color;

  @override
  int get hashCode => Object.hash(label, color);
}

/// 柱状图的一根柱（可堆叠：[values] 与系列一一对应，自下而上）。
@immutable
class SrsBarDatum {
  const SrsBarDatum({
    required this.label,
    required this.values,
    required this.title,
  });

  /// 横轴标签（短）。
  final String label;

  /// 气泡标题（完整日期 / 区间）。
  final String title;
  final List<int> values;

  int get total => values.fold<int>(0, (int a, int b) => a + b);

  @override
  bool operator ==(Object other) =>
      other is SrsBarDatum &&
      other.label == label &&
      other.title == title &&
      listEquals(other.values, values);

  @override
  int get hashCode => Object.hash(label, title, Object.hashAll(values));
}

/// 图表的通用尺寸：纵轴标签区 + 底部横轴标签区。
const double _kBottomPadding = 20;

TextStyle _axisStyle(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return tokens.type.metadata.copyWith(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}

/// 可点按 / 悬停的（堆叠）柱状图。
class SrsBarChart extends StatefulWidget {
  const SrsBarChart({
    required this.bars,
    required this.series,
    required this.scaleOf,
    required this.valueText,
    super.key,
    this.height = 176,
    this.showTotalInTooltip = true,
    this.extraTooltip,
  });

  final List<SrsBarDatum> bars;
  final List<SrsChartSeries> series;

  /// 最大柱高 → 整条纵轴的刻度（[statCountAxisScale] / [statDurationAxisScale]）。
  final StatAxisScale Function(int max) scaleOf;

  /// 值 → 气泡里的文字（次数 / 时长）。
  final String Function(int value) valueText;
  final double height;
  final bool showTotalInTooltip;

  /// 气泡末尾追加的一行（如按小时的正确率）。
  final String? Function(int index)? extraTooltip;

  @override
  State<SrsBarChart> createState() => _SrsBarChartState();
}

class _SrsBarChartState extends State<SrsBarChart> {
  int? _selected;

  @override
  void didUpdateWidget(SrsBarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null && _selected! >= widget.bars.length) _selected = null;
  }

  int? _indexAt(double x, double width, double left) {
    final int n = widget.bars.length;
    if (n == 0 || x < left - 4) return null;
    final double step = (width - left) / n;
    return ((x - left) / step).floor().clamp(0, n - 1);
  }

  List<String> _tooltipLines(int i) {
    final SrsBarDatum d = widget.bars[i];
    final List<String> lines = <String>[d.title];
    final bool multi = widget.series.length > 1;
    for (int s = 0; s < widget.series.length && s < d.values.length; s++) {
      if (multi && d.values[s] == 0) continue;
      lines.add(
        multi
            ? '${widget.series[s].label}  ${widget.valueText(d.values[s])}'
            : widget.valueText(d.values[s]),
      );
    }
    if (multi && widget.showTotalInTooltip) {
      lines.add('${t.srs_stats_total}  ${widget.valueText(d.total)}');
    }
    if (widget.extraTooltip?.call(i) case final String extra) lines.add(extra);
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = _axisStyle(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int max = widget.bars.fold<int>(
      0,
      (int m, SrsBarDatum d) => math.max(m, d.total),
    );
    final StatAxisScale scale = widget.scaleOf(math.max(1, max));
    final double left = statAxisLeftPadding(scale.labels, style, 32);
    final int? sel = _selected;
    return Semantics(
      container: true,
      label: sel == null ? null : _tooltipLines(sel).join(', '),
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = box.maxWidth;
            void pick(Offset p, {bool toggle = false}) {
              final int? i = _indexAt(p.dx, width, left);
              setState(() => _selected = toggle && i == _selected ? null : i);
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
                  painter: _SrsBarPainter(
                    bars: widget.bars,
                    colors: <Color>[
                      for (final SrsChartSeries s in widget.series) s.color,
                    ],
                    scale: scale,
                    left: left,
                    labelStyle: style,
                    gridColor: scheme.onSurfaceVariant,
                    radius: tokens.radii.chipCorner,
                    gapColor: scheme.surfaceContainerLow,
                    selected: sel,
                    tooltip: sel == null ? null : _tooltipLines(sel),
                    tooltipSwatches: sel == null || widget.series.length < 2
                        ? null
                        : <Color?>[
                            null,
                            for (
                              int s = 0;
                              s < widget.series.length &&
                                  s < widget.bars[sel].values.length;
                              s++
                            )
                              if (widget.bars[sel].values[s] != 0)
                                widget.series[s].color,
                          ],
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

/// 画网格线 + 纵轴标签，返回绘图区高度。
double _paintGrid(
  Canvas canvas,
  Size size,
  StatAxisScale scale,
  double left,
  TextStyle style,
  Color ink,
) {
  final double chartHeight = size.height - _kBottomPadding;
  final Paint grid = Paint()
    ..color = ink.withValues(alpha: 0.14)
    ..strokeWidth = 1;
  final Paint base = Paint()
    ..color = ink.withValues(alpha: 0.4)
    ..strokeWidth = 1;
  for (int i = 0; i < scale.ticks.length; i++) {
    final double y = chartHeight - chartHeight * scale.ticks[i] / scale.max;
    canvas.drawLine(
      Offset(left, y),
      Offset(size.width, y),
      i == 0 ? base : grid,
    );
    final TextPainter tp = TextPainter(
      text: TextSpan(text: scale.labels[i], style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(left - tp.width - 4, y - tp.height / 2));
  }
  return chartHeight;
}

/// 画横轴标签（按实测宽度抽稀，末项恒标）。
void _paintXLabels(
  Canvas canvas,
  Size size,
  List<String> labels,
  double left,
  double Function(int) centerOf,
  double chartHeight,
  TextStyle style,
) {
  final List<TextPainter> tps = <TextPainter>[
    for (final String l in labels)
      TextPainter(
        text: TextSpan(text: l, style: style),
        textDirection: TextDirection.ltr,
      )..layout(),
  ];
  for (final StatAxisLabelSlot slot in statXAxisLabelSlots(
    count: labels.length,
    minEvery: 1,
    centerOf: centerOf,
    widthOf: (int i) => tps[i].width,
    minX: left - 4,
    maxX: size.width,
    minGap: 10,
  )) {
    tps[slot.index].paint(canvas, Offset(slot.left, chartHeight + 4));
  }
}

/// 气泡：在 [anchor]（列中心、柱顶）上方画多行文字，夹在画布内。
void _paintTooltip(
  Canvas canvas,
  Size size,
  Offset anchor,
  List<String> lines,
  TextStyle style,
  Color background, {
  List<Color?>? swatches,
}) {
  const double pad = 8;
  const double swatch = 8;
  final List<TextPainter> tps = <TextPainter>[
    for (final String l in lines)
      TextPainter(
        text: TextSpan(text: l, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(40, size.width - 2 * pad - swatch - 6)),
  ];
  double w = 0, h = 0;
  for (int i = 0; i < tps.length; i++) {
    final bool hasSwatch = swatches != null && i < swatches.length
        ? swatches[i] != null
        : false;
    w = math.max(w, tps[i].width + (hasSwatch ? swatch + 6 : 0));
    h += tps[i].height;
  }
  final double bw = w + pad * 2;
  final double bh = h + pad * 2;
  double x = anchor.dx - bw / 2;
  x = x.clamp(0, math.max(0, size.width - bw)).toDouble();
  double y = anchor.dy - bh - 8;
  if (y < 0) {
    y = math.min(size.height - bh, anchor.dy + 8).clamp(0, size.height);
  }
  final RRect r = RRect.fromRectAndRadius(
    Rect.fromLTWH(x, y, bw, bh),
    const Radius.circular(8),
  );
  canvas.drawRRect(r, Paint()..color = background);
  double cy = y + pad;
  for (int i = 0; i < tps.length; i++) {
    double cx = x + pad;
    final Color? sw = swatches != null && i < swatches.length
        ? swatches[i]
        : null;
    if (sw != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx, cy + (tps[i].height - swatch) / 2, swatch, swatch),
          const Radius.circular(2),
        ),
        Paint()..color = sw,
      );
      cx += swatch + 6;
    }
    tps[i].paint(canvas, Offset(cx, cy));
    cy += tps[i].height;
  }
}

class _SrsBarPainter extends CustomPainter {
  _SrsBarPainter({
    required this.bars,
    required this.colors,
    required this.scale,
    required this.left,
    required this.labelStyle,
    required this.gridColor,
    required this.radius,
    required this.gapColor,
    required this.selected,
    required this.tooltip,
    required this.tooltipSwatches,
    required this.tooltipBackground,
    required this.tooltipStyle,
  });

  final List<SrsBarDatum> bars;
  final List<Color> colors;
  final StatAxisScale scale;
  final double left;
  final TextStyle labelStyle;
  final Color gridColor;
  final Radius radius;
  final Color gapColor;
  final int? selected;
  final List<String>? tooltip;
  final List<Color?>? tooltipSwatches;
  final Color tooltipBackground;
  final TextStyle tooltipStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final double chartHeight = _paintGrid(
      canvas,
      size,
      scale,
      left,
      labelStyle,
      gridColor,
    );
    final int n = bars.length;
    if (n == 0) return;
    final double step = (size.width - left) / n;
    final double barWidth = math.max(1, math.min(step * 0.72, 28));
    double centerOf(int i) => left + step * i + step / 2;
    final int? sel = selected;
    if (sel != null) {
      canvas.drawRect(
        Rect.fromLTWH(left + step * sel, 0, step, chartHeight),
        Paint()..color = gridColor.withValues(alpha: 0.10),
      );
    }
    for (int i = 0; i < n; i++) {
      final SrsBarDatum d = bars[i];
      final int total = d.total;
      if (total <= 0) continue;
      final double x = centerOf(i) - barWidth / 2;
      final double top = chartHeight - total / scale.max * chartHeight;
      final RRect clip = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, top, barWidth, chartHeight - top),
        topLeft: radius,
        topRight: radius,
      );
      canvas.save();
      canvas.clipRRect(clip);
      int acc = 0;
      double segBottom = chartHeight;
      for (int s = 0; s < d.values.length && s < colors.length; s++) {
        final int v = d.values[s];
        if (v <= 0) continue;
        acc += v;
        final double segTop = chartHeight - acc / scale.max * chartHeight;
        canvas.drawRect(
          Rect.fromLTRB(x, segTop, x + barWidth, segBottom),
          Paint()..color = colors[s],
        );
        // 段间 2px 表面色缝（dataviz：相邻填充之间留缝，深浅色都分得开）。
        if (acc < total && barWidth >= 4) {
          canvas.drawLine(
            Offset(x, segTop),
            Offset(x + barWidth, segTop),
            Paint()
              ..color = gapColor
              ..strokeWidth = 1.5,
          );
        }
        segBottom = segTop;
      }
      canvas.restore();
    }
    _paintXLabels(
      canvas,
      size,
      <String>[for (final SrsBarDatum d in bars) d.label],
      left,
      centerOf,
      chartHeight,
      labelStyle,
    );
    final List<String>? lines = tooltip;
    if (sel != null && lines != null) {
      final double top =
          chartHeight - bars[sel].total / scale.max * chartHeight;
      _paintTooltip(
        canvas,
        size,
        Offset(centerOf(sel), math.min(top, chartHeight - 4)),
        lines,
        tooltipStyle,
        tooltipBackground,
        swatches: tooltipSwatches,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SrsBarPainter old) =>
      !listEquals(bars, old.bars) ||
      !listEquals(colors, old.colors) ||
      scale.max != old.scale.max ||
      left != old.left ||
      labelStyle != old.labelStyle ||
      gridColor != old.gridColor ||
      selected != old.selected ||
      !listEquals(tooltip, old.tooltip) ||
      tooltipBackground != old.tooltipBackground;
}

/// 可悬停的单系列折线图（带浅色面积）。
class SrsLineChart extends StatefulWidget {
  const SrsLineChart({
    required this.values,
    required this.labels,
    required this.titles,
    required this.color,
    required this.valueText,
    super.key,
    this.height = 168,
  });

  final List<int> values;

  /// 横轴短标签。
  final List<String> labels;

  /// 气泡标题（完整日期）。
  final List<String> titles;
  final Color color;
  final String Function(int value) valueText;
  final double height;

  @override
  State<SrsLineChart> createState() => _SrsLineChartState();
}

class _SrsLineChartState extends State<SrsLineChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = _axisStyle(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int max = widget.values.fold<int>(0, math.max);
    final StatAxisScale scale = statCountAxisScale(math.max(1, max));
    final double left = statAxisLeftPadding(scale.labels, style, 32);
    final int n = widget.values.length;
    final int? sel = _selected != null && _selected! < n ? _selected : null;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double width = box.maxWidth;
          void pick(Offset p, {bool toggle = false}) {
            if (n == 0) return;
            final double step = n > 1 ? (width - left) / (n - 1) : 0;
            final int i = step == 0
                ? 0
                : ((p.dx - left) / step).round().clamp(0, n - 1);
            setState(() => _selected = toggle && i == _selected ? null : i);
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
                painter: _SrsLinePainter(
                  values: widget.values,
                  labels: widget.labels,
                  color: widget.color,
                  scale: scale,
                  left: left,
                  labelStyle: style,
                  gridColor: scheme.onSurfaceVariant,
                  surface: scheme.surfaceContainerLow,
                  selected: sel,
                  tooltip: sel == null
                      ? null
                      : <String>[
                          widget.titles[sel],
                          widget.valueText(widget.values[sel]),
                        ],
                  tooltipBackground: scheme.inverseSurface,
                  tooltipStyle: style.copyWith(color: scheme.onInverseSurface),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SrsLinePainter extends CustomPainter {
  _SrsLinePainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.scale,
    required this.left,
    required this.labelStyle,
    required this.gridColor,
    required this.surface,
    required this.selected,
    required this.tooltip,
    required this.tooltipBackground,
    required this.tooltipStyle,
  });

  final List<int> values;
  final List<String> labels;
  final Color color;
  final StatAxisScale scale;
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
    final double chartHeight = _paintGrid(
      canvas,
      size,
      scale,
      left,
      labelStyle,
      gridColor,
    );
    final int n = values.length;
    if (n == 0) return;
    final double step = n > 1 ? (size.width - left - 4) / (n - 1) : 0;
    double xAt(int i) =>
        n > 1 ? left + step * i : left + (size.width - left) / 2;
    double yAt(int v) => chartHeight - v / scale.max * chartHeight;
    final Path line = Path()..moveTo(xAt(0), yAt(values[0]));
    for (int i = 1; i < n; i++) {
      line.lineTo(xAt(i), yAt(values[i]));
    }
    final Path area = Path.from(line)
      ..lineTo(xAt(n - 1), chartHeight)
      ..lineTo(xAt(0), chartHeight)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    _paintXLabels(canvas, size, labels, left, xAt, chartHeight, labelStyle);
    final int? sel = selected;
    final List<String>? lines = tooltip;
    if (sel != null && lines != null) {
      final Offset p = Offset(xAt(sel), yAt(values[sel]));
      canvas.drawLine(
        Offset(p.dx, 0),
        Offset(p.dx, chartHeight),
        Paint()
          ..color = gridColor.withValues(alpha: 0.4)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(p, 6, Paint()..color = surface);
      canvas.drawCircle(p, 4, Paint()..color = color);
      _paintTooltip(canvas, size, p, lines, tooltipStyle, tooltipBackground);
    }
  }

  @override
  bool shouldRepaint(covariant _SrsLinePainter old) =>
      !listEquals(values, old.values) ||
      !listEquals(labels, old.labels) ||
      color != old.color ||
      left != old.left ||
      labelStyle != old.labelStyle ||
      selected != old.selected ||
      !listEquals(tooltip, old.tooltip);
}

/// 环形图的一段。
@immutable
class SrsDonutSegment {
  const SrsDonutSegment(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;
}

/// 环形图 + 可点选图例（选中的段在环心显示数量与占比）。窄于 [kWideMin] 时图例
/// 落到环下方，否则在右侧。
class SrsDonutChart extends StatefulWidget {
  const SrsDonutChart({
    required this.segments,
    required this.centerLabel,
    super.key,
    this.size = 148,
  });

  static const double kWideMin = 360;

  final List<SrsDonutSegment> segments;

  /// 没选中时环心的说明（如「共 120 张卡」）。
  final String centerLabel;
  final double size;

  @override
  State<SrsDonutChart> createState() => _SrsDonutChartState();
}

class _SrsDonutChartState extends State<SrsDonutChart> {
  int? _selected;

  int get _total =>
      widget.segments.fold<int>(0, (int a, SrsDonutSegment s) => a + s.value);

  String _percent(int v) =>
      _total == 0 ? '0%' : '${(v * 100 / _total).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int? sel = _selected;
    final SrsDonutSegment? picked = sel == null ? null : widget.segments[sel];
    final Widget ring = SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          CustomPaint(
            size: Size.square(widget.size),
            painter: _SrsDonutPainter(
              segments: widget.segments,
              selected: sel,
              surface: scheme.surfaceContainerLow,
              empty: scheme.outlineVariant,
            ),
          ),
          Padding(
            padding: EdgeInsets.all(widget.size * 0.22),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    picked == null ? '$_total' : '${picked.value}',
                    style: context.fushiType.headlineSmall.tabular.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    picked == null
                        ? widget.centerLabel
                        : '${picked.label} · ${_percent(picked.value)}',
                    style: tokens.type.metadata.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    final Widget legend = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < widget.segments.length; i++)
          InkWell(
            key: ValueKey<String>('srs-donut-legend-$i'),
            borderRadius: BorderRadius.all(tokens.radii.chipCorner),
            onTap: () => setState(() => _selected = _selected == i ? null : i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              child: Row(
                children: <Widget>[
                  _Swatch(color: widget.segments[i].color),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(
                      widget.segments[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.metadata.copyWith(
                        color: scheme.onSurface,
                        fontWeight: i == sel ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.segments[i].value}',
                    style: tokens.type.metadata.tabular.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      _percent(widget.segments[i].value),
                      textAlign: TextAlign.end,
                      style: tokens.type.metadata.tabular.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (box.maxWidth < SrsDonutChart.kWideMin) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(child: ring),
              SizedBox(height: tokens.spacing.gap),
              legend,
            ],
          );
        }
        return Row(
          children: <Widget>[
            ring,
            SizedBox(width: tokens.spacing.card),
            Expanded(child: legend),
          ],
        );
      },
    );
  }
}

class _SrsDonutPainter extends CustomPainter {
  _SrsDonutPainter({
    required this.segments,
    required this.selected,
    required this.surface,
    required this.empty,
  });

  final List<SrsDonutSegment> segments;
  final int? selected;
  final Color surface;
  final Color empty;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = size.width * 0.13;
    final Rect rect = Offset.zero & size;
    final Rect arc = rect.deflate(stroke / 2 + 3);
    final int total = segments.fold<int>(
      0,
      (int a, SrsDonutSegment s) => a + s.value,
    );
    if (total == 0) {
      canvas.drawArc(
        arc,
        0,
        math.pi * 2,
        false,
        Paint()
          ..color = empty
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      return;
    }
    final int nonZero = segments
        .where((SrsDonutSegment s) => s.value > 0)
        .length;
    // 段间 2px 表面色缝：按弧长换算的角度。
    final double gap = nonZero > 1 ? 2 / (arc.width / 2) : 0;
    double start = -math.pi / 2;
    for (int i = 0; i < segments.length; i++) {
      final SrsDonutSegment s = segments[i];
      if (s.value <= 0) continue;
      final double sweep = s.value / total * math.pi * 2;
      final bool picked = selected == i;
      canvas.drawArc(
        picked ? arc.inflate(3) : arc,
        start + gap / 2,
        math.max(0.001, sweep - gap),
        false,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = picked ? stroke + 4 : stroke,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _SrsDonutPainter old) =>
      selected != old.selected ||
      surface != old.surface ||
      segments.length != old.segments.length ||
      !_sameSegments(segments, old.segments);

  static bool _sameSegments(List<SrsDonutSegment> a, List<SrsDonutSegment> b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i].value != b[i].value || a[i].color != b[i].color) return false;
    }
    return true;
  }
}

/// 图例 / 列表里的小色块。
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: color,
      borderRadius: const BorderRadius.all(Radius.circular(3)),
    ),
  );
}

/// 图例：色块 + 系列名（多系列图下方，颜色从不单独承载含义）。
class SrsChartLegend extends StatelessWidget {
  const SrsChartLegend({required this.series, super.key});

  final List<SrsChartSeries> series;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color ink = Theme.of(context).colorScheme.onSurfaceVariant;
    return Wrap(
      spacing: tokens.spacing.card,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (final SrsChartSeries s in series)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Swatch(color: s.color),
              const SizedBox(width: 6),
              Text(s.label, style: tokens.type.metadata.copyWith(color: ink)),
            ],
          ),
      ],
    );
  }
}

/// 百分比堆叠条（今日评分分布、评分按钮）：段间留 2px 缝，两端圆角。
class SrsStackedMeter extends StatelessWidget {
  const SrsStackedMeter({
    required this.values,
    required this.colors,
    super.key,
    this.height = 12,
  });

  final List<int> values;
  final List<Color> colors;
  final double height;

  @override
  Widget build(BuildContext context) {
    final int total = values.fold<int>(0, (int a, int b) => a + b);
    final Color empty = statHeatmapEmptyColors(context).$1;
    if (total == 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: empty,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(
          children: <Widget>[
            for (int i = 0; i < values.length; i++)
              if (values[i] > 0)
                Expanded(
                  flex: math.max(1, (values[i] * 1000 / total).round()),
                  child: Container(
                    margin: EdgeInsetsDirectional.only(
                      end: _hasLaterValue(i) ? 2 : 0,
                    ),
                    color: colors[i % colors.length],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  bool _hasLaterValue(int i) {
    for (int k = i + 1; k < values.length; k++) {
      if (values[k] > 0) return true;
    }
    return false;
  }
}

/// 日历热力图：一列 = 一周（周一在上），列数按可用宽度取（最多 53 周），最近
/// 一周在最右。点按格子在下方说明行显示该日与复习数。
class SrsCalendarHeatmap extends StatefulWidget {
  const SrsCalendarHeatmap({
    required this.countsByDay,
    required this.today,
    required this.dayLabel,
    required this.monthLabel,
    super.key,
  });

  /// SRS 日序号 → 复习数。
  final Map<int, int> countsByDay;
  final int today;

  /// 日序号 → 完整日期文字（说明行）。
  final String Function(int day) dayLabel;

  /// 日序号（某月 1 日所在列）→ 月份短标签。
  final String Function(int day) monthLabel;

  @override
  State<SrsCalendarHeatmap> createState() => _SrsCalendarHeatmapState();
}

class _SrsCalendarHeatmapState extends State<SrsCalendarHeatmap> {
  int? _selected;

  static const double _gap = 3;

  /// 5 档：0 = 空格，1..4 按当前可见范围最大值的四分位（每档至少 1 次）。
  int _level(int count, int max) {
    if (count <= 0 || max <= 0) return 0;
    return (count * 4 / max).ceil().clamp(1, 4);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsStatColors colors = SrsStatColors.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle small = tokens.type.metadata.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double width = box.maxWidth;
        final int weeks = ((width + _gap) / (11 + _gap)).floor().clamp(8, 53);
        final double cell = math.min(16, (width - (weeks - 1) * _gap) / weeks);
        // 最右一列 = 今天所在周（周一起）。
        final int todayWeekday = srsDayToDateWeekday(widget.today);
        final int lastMonday = widget.today - (todayWeekday - 1);
        final int firstMonday = lastMonday - (weeks - 1) * 7;
        int max = 0;
        for (int d = firstMonday; d <= widget.today; d++) {
          max = math.max(max, widget.countsByDay[d] ?? 0);
        }
        final double gridWidth = weeks * cell + (weeks - 1) * _gap;
        final int? sel = _selected;
        final List<Widget> monthLabels = <Widget>[];
        for (int w = 0; w < weeks; w++) {
          final int monday = firstMonday + w * 7;
          for (int k = 0; k < 7; k++) {
            final int d = monday + k;
            if (srsDayOfMonth(d) == 1 && w < weeks - 1) {
              monthLabels.add(
                Positioned(
                  left: w * (cell + _gap),
                  child: Text(widget.monthLabel(d), style: small),
                ),
              );
            }
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: gridWidth,
              height: 16,
              child: Stack(clipBehavior: Clip.hardEdge, children: monthLabels),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: gridWidth,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int w = 0; w < weeks; w++) ...<Widget>[
                    if (w > 0) const SizedBox(width: _gap),
                    Column(
                      children: <Widget>[
                        for (int k = 0; k < 7; k++) ...<Widget>[
                          if (k > 0) const SizedBox(height: _gap),
                          _cell(
                            firstMonday + w * 7 + k,
                            cell,
                            colors,
                            max,
                            scheme,
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              child: Text(
                key: ValueKey<int?>(sel),
                sel == null
                    ? ' '
                    : '${widget.dayLabel(sel)} · '
                          '${t.srs_stats_reviews_count(n: widget.countsByDay[sel] ?? 0)}',
                style: small.copyWith(color: scheme.onSurface),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _cell(
    int day,
    double size,
    SrsStatColors colors,
    int max,
    ColorScheme scheme,
  ) {
    if (day > widget.today) return SizedBox.square(dimension: size);
    final int count = widget.countsByDay[day] ?? 0;
    final int level = _level(count, max);
    final bool picked = _selected == day;
    return MouseRegion(
      onEnter: (_) => setState(() => _selected = day),
      child: GestureDetector(
        onTap: () => setState(() => _selected = picked ? null : day),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: level == 0 ? colors.empty : colors.heat(level),
            borderRadius: BorderRadius.circular(math.min(3, size / 4)),
            border: picked || day == widget.today
                ? Border.all(color: scheme.onSurface, width: picked ? 2 : 1)
                : null,
          ),
        ),
      ),
    );
  }
}

/// 日序号 → 星期（1 = 周一 … 7 = 周日）。
int srsDayToDateWeekday(int day) => srsDayToDate(day).weekday;

/// 日序号 → 当月第几日。
int srsDayOfMonth(int day) => srsDayToDate(day).day;

/// 色环上离 [taken] 里每个色相都最远的色相（5° 一档）。
double srsFarthestHue(List<double> taken) {
  double best = 0;
  double bestDistance = -1;
  for (int c = 0; c < 360; c += 5) {
    double nearest = 360;
    for (final double t in taken) {
      final double d = (c - t).abs() % 360;
      nearest = math.min(nearest, math.min(d, 360 - d));
    }
    if (nearest > bestDistance) {
      bestDistance = nearest;
      best = c.toDouble();
    }
  }
  return best;
}
