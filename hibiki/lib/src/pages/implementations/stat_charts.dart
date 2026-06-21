import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 统计图表的每日数据点（阅读统计 / 视频统计共用）。
class StatDayData {
  StatDayData({required this.dateKey, this.label});
  final String dateKey;

  /// 可选横轴标签覆盖（趋势聚合后的周/月桶用，如 `W25` / `06`）；为 null 时
  /// [statDayLabel] 回退到 dateKey 的 `MM-DD`。
  final String? label;
  int chars = 0;
  int ms = 0;
}

/// 取 [StatDayData.chars] 作图表值（阅读统计默认）。用顶层静态 tear-off 而非
/// 闭包，使 [StatBarChartPainter.shouldRepaint] 的函数相等比较稳定（每帧新建的
/// 闭包恒不相等会导致每帧重绘）。
int statCharsValue(StatDayData d) => d.chars;

/// 取 [StatDayData.ms] 作图表值（视频统计：删字数后以观看时长为准）。
int statMsValue(StatDayData d) => d.ms;

/// 默认横轴标签：取 dateKey 的 `MM-DD`（长度足够时），否则原样返回。趋势聚合后
/// 周/月桶传自定义 [StatBarChartPainter.labelOf] 覆盖此默认（如 `W25` / `06`）。
/// 用顶层 tear-off 而非闭包，保 [StatBarChartPainter.shouldRepaint] 函数相等稳定。
String statDayLabel(StatDayData d) =>
    d.label ?? (d.dateKey.length >= 10 ? d.dateKey.substring(5) : d.dateKey);

/// 把字数格式化为坐标轴标签（万 / k / 原值）。
String formatStatCharsAxis(int chars) {
  if (chars >= 10000) return '${(chars / 10000).toStringAsFixed(1)}万';
  if (chars >= 1000) return '${(chars / 1000).toStringAsFixed(1)}k';
  return chars.toString();
}

/// 把阅读速度（字/小时）格式化为折线图纵轴标签。整数 cph 直接显示；>= 1000 收成
/// `k`（如 1.2k）避免标签过宽。用顶层 tear-off 而非闭包，保 [StatLineChartPainter]
/// 的 shouldRepaint 函数相等稳定。
String formatStatCphAxis(double cph) {
  final int v = cph.round();
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v.toString();
}

/// 把毫秒时长格式化为坐标轴标签。不足 1 分钟时回退到秒（如 `30s`）而非整除成
/// `0m`——后者会让整条纵轴退化成 `0m 0m 0m 0m 0m`（观看时长不足 1 分钟时所有
/// 刻度都被 `ms ~/ 60000` 取整为 0）。
String formatStatDurationAxis(int ms) {
  if (ms >= 3600000) return '${ms ~/ 3600000}h';
  if (ms >= 60000) return '${ms ~/ 60000}m';
  if (ms > 0) return '${ms ~/ 1000}s';
  return '0';
}

/// 今日按小时柱状图画笔（0-23 小时，值为毫秒）。阅读统计与视频统计共用。
class StatHourlyChartPainter extends CustomPainter {
  StatHourlyChartPainter({
    required this.hourlyMs,
    required this.barColor,
    required this.barRadius,
    required this.labelColor,
    required this.labelStyle,
  });

  final List<int> hourlyMs;
  final Color barColor;
  final Radius barRadius;
  final Color labelColor;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (hourlyMs.isEmpty) return;

    final maxMs = hourlyMs.fold<int>(0, (prev, ms) => ms > prev ? ms : prev);
    if (maxMs == 0) return;

    const bottomPadding = 20.0;
    const leftPadding = 32.0;
    final chartHeight = size.height - bottomPadding;
    final chartWidth = size.width - leftPadding;
    final step = chartWidth / 24;
    final barWidth = step * 0.7;
    final gap = step * 0.15;

    final paint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final gridPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    canvas.drawLine(
      const Offset(leftPadding, 0),
      Offset(leftPadding, chartHeight),
      axisPaint,
    );
    canvas.drawLine(
      Offset(leftPadding, chartHeight),
      Offset(size.width, chartHeight),
      axisPaint,
    );

    const int yTicks = 4;
    for (int i = 0; i <= yTicks; i++) {
      final value = (maxMs * i / yTicks).round();
      final y = chartHeight - (chartHeight * i / yTicks);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: formatStatDurationAxis(value), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < 24; i++) {
      final x = leftPadding + i * step + gap;
      final barHeight = (hourlyMs[i] / maxMs) * chartHeight;

      if (hourlyMs[i] > 0) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, chartHeight - barHeight, barWidth, barHeight),
          barRadius,
        );
        canvas.drawRRect(rect, paint);
      }

      if (i % 3 == 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: i.toString().padLeft(2, '0'),
            style: labelStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(x + barWidth / 2 - tp.width / 2, chartHeight + 4),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant StatHourlyChartPainter oldDelegate) =>
      !listEquals(hourlyMs, oldDelegate.hourlyMs) ||
      barColor != oldDelegate.barColor ||
      barRadius != oldDelegate.barRadius ||
      labelColor != oldDelegate.labelColor ||
      labelStyle != oldDelegate.labelStyle;
}

/// 最近 N 天柱状图画笔。阅读统计默认画字数（[statCharsValue]），视频统计删字数后
/// 画观看时长（[statMsValue]）。[valueOf] / [labelFormatter] 用顶层静态 tear-off
/// 传入，使 [shouldRepaint] 的函数相等比较稳定。
class StatBarChartPainter extends CustomPainter {
  StatBarChartPainter({
    required this.data,
    required this.barColor,
    required this.barRadius,
    required this.labelColor,
    required this.labelStyle,
    this.valueOf = statCharsValue,
    this.labelFormatter = formatStatCharsAxis,
    this.labelOf = statDayLabel,
  });

  final List<StatDayData> data;
  final Color barColor;
  final Radius barRadius;
  final Color labelColor;
  final TextStyle labelStyle;
  final int Function(StatDayData) valueOf;
  final String Function(int) labelFormatter;

  /// 把数据点映射成横轴标签（默认 [statDayLabel] 取 `MM-DD`；趋势聚合传自定义）。
  final String Function(StatDayData) labelOf;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxValue =
        data.fold<int>(0, (prev, d) => valueOf(d) > prev ? valueOf(d) : prev);
    if (maxValue == 0) return;

    const bottomPadding = 20.0;
    const leftPadding = 36.0;
    final chartHeight = size.height - bottomPadding;
    final chartWidth = size.width - leftPadding;
    final barWidth = (chartWidth / data.length) * 0.7;
    final gap = (chartWidth / data.length) * 0.3;
    final step = chartWidth / data.length;

    final paint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final gridPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    canvas.drawLine(
      const Offset(leftPadding, 0),
      Offset(leftPadding, chartHeight),
      axisPaint,
    );
    canvas.drawLine(
      Offset(leftPadding, chartHeight),
      Offset(size.width, chartHeight),
      axisPaint,
    );

    const int yTicks = 4;
    for (int i = 0; i <= yTicks; i++) {
      final value = (maxValue * i / yTicks).round();
      final y = chartHeight - (chartHeight * i / yTicks);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: labelFormatter(value), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < data.length; i++) {
      final d = data[i];
      final x = leftPadding + i * step + gap / 2;
      final value = valueOf(d);
      final barHeight = (value / maxValue) * chartHeight;

      if (value > 0) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, chartHeight - barHeight, barWidth, barHeight),
          barRadius,
        );
        canvas.drawRRect(rect, paint);
      }

      if (i % 5 == 0 || i == data.length - 1) {
        final tp = TextPainter(
          text: TextSpan(
            text: labelOf(d),
            style: labelStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(x + barWidth / 2 - tp.width / 2, chartHeight + 4),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant StatBarChartPainter oldDelegate) =>
      !listEquals(data, oldDelegate.data) ||
      barColor != oldDelegate.barColor ||
      barRadius != oldDelegate.barRadius ||
      labelColor != oldDelegate.labelColor ||
      labelStyle != oldDelegate.labelStyle ||
      valueOf != oldDelegate.valueOf ||
      labelFormatter != oldDelegate.labelFormatter ||
      labelOf != oldDelegate.labelOf;
}

/// 折线图的一条线：值序列 + 颜色 + 线宽 + 是否描点。值与 [StatLineChartPainter]
/// 的 x 轴等距对齐（第 i 个值对应第 i 个横轴刻度）。
class StatLineSeries {
  const StatLineSeries({
    required this.values,
    required this.color,
    this.strokeWidth = 2.0,
    this.dashed = false,
  });

  final List<double> values;
  final Color color;
  final double strokeWidth;

  /// 虚线（用于移动平均线，与原始速度线区分）。
  final bool dashed;
}

/// 折线趋势图画笔：在同一坐标系画多条 [StatLineSeries]（如原始速度 + 移动平均），
/// 并在 [anomalies] 为 true 的点上（取 [series] 第 0 条线的值）画异常标记圆点。
/// [labelFormatter] 把纵轴值格式化为标签（如 cph 用整数 + 单位）；[xLabels] 是横轴
/// 标签（按 [labelEvery] 抽稀显示）。所有样式经参数传入（无内联 fontSize），与
/// [StatBarChartPainter] 同范式，使 [shouldRepaint] 的相等比较稳定。
class StatLineChartPainter extends CustomPainter {
  StatLineChartPainter({
    required this.series,
    required this.xLabels,
    required this.anomalies,
    required this.anomalyColor,
    required this.labelColor,
    required this.labelStyle,
    required this.labelFormatter,
    this.labelEvery = 5,
  });

  final List<StatLineSeries> series;
  final List<String> xLabels;
  final List<bool> anomalies;
  final Color anomalyColor;
  final Color labelColor;
  final TextStyle labelStyle;
  final String Function(double) labelFormatter;
  final int labelEvery;

  /// 所有线里的最大点数（决定横轴刻度数）。
  int get _pointCount => series.fold<int>(
      0, (int p, StatLineSeries s) => math.max(p, s.values.length));

  @override
  void paint(Canvas canvas, Size size) {
    final int n = _pointCount;
    if (n == 0) return;

    double maxValue = 0;
    for (final StatLineSeries s in series) {
      for (final double v in s.values) {
        if (v > maxValue) maxValue = v;
      }
    }
    if (maxValue <= 0) maxValue = 1; // 全零时退化成平底线，避免除零。

    const double bottomPadding = 20.0;
    const double leftPadding = 40.0;
    final double chartHeight = size.height - bottomPadding;
    final double chartWidth = size.width - leftPadding;
    // 单点时居中，多点时等距铺满。
    final double step = n > 1 ? chartWidth / (n - 1) : 0;

    final Paint axisPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final Paint gridPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    canvas.drawLine(
      const Offset(leftPadding, 0),
      Offset(leftPadding, chartHeight),
      axisPaint,
    );
    canvas.drawLine(
      Offset(leftPadding, chartHeight),
      Offset(size.width, chartHeight),
      axisPaint,
    );

    const int yTicks = 4;
    for (int i = 0; i <= yTicks; i++) {
      final double value = maxValue * i / yTicks;
      final double y = chartHeight - (chartHeight * i / yTicks);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final TextPainter tp = TextPainter(
        text: TextSpan(text: labelFormatter(value), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    double xAt(int i) =>
        n > 1 ? leftPadding + i * step : leftPadding + chartWidth / 2;
    double yAt(double v) => chartHeight - (v / maxValue) * chartHeight;

    for (final StatLineSeries s in series) {
      if (s.values.isEmpty) continue;
      final Paint linePaint = Paint()
        ..color = s.color
        ..strokeWidth = s.strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      Offset? prev;
      for (int i = 0; i < s.values.length; i++) {
        final Offset cur = Offset(xAt(i), yAt(s.values[i]));
        if (prev != null) {
          if (s.dashed) {
            _drawDashedLine(canvas, prev, cur, linePaint);
          } else {
            canvas.drawLine(prev, cur, linePaint);
          }
        } else if (s.values.length == 1) {
          // 只有一个点时画个实心点，否则什么都看不到。
          canvas.drawCircle(cur, s.strokeWidth + 1, Paint()..color = s.color);
        }
        prev = cur;
      }
    }

    // 异常点标记：取第 0 条线（原始速度）的值定位，画空心圈 + 实心点。
    if (series.isNotEmpty) {
      final StatLineSeries base = series.first;
      final Paint markerStroke = Paint()
        ..color = anomalyColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final Paint markerFill = Paint()..color = anomalyColor;
      for (int i = 0; i < anomalies.length && i < base.values.length; i++) {
        if (!anomalies[i]) continue;
        final Offset c = Offset(xAt(i), yAt(base.values[i]));
        canvas.drawCircle(c, 4, markerFill);
        canvas.drawCircle(c, 6, markerStroke);
      }
    }

    // 横轴标签（抽稀）。
    for (int i = 0; i < xLabels.length && i < n; i++) {
      if (i % labelEvery != 0 && i != n - 1) continue;
      final TextPainter tp = TextPainter(
        text: TextSpan(text: xLabels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(xAt(i) - tp.width / 2, chartHeight + 4));
    }
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const double dashLen = 5;
    const double gapLen = 4;
    final double totalLen = (to - from).distance;
    if (totalLen == 0) return;
    final Offset dir = (to - from) / totalLen;
    double drawn = 0;
    bool on = true;
    Offset cursor = from;
    while (drawn < totalLen) {
      final double seg = math.min(on ? dashLen : gapLen, totalLen - drawn);
      final Offset next = cursor + dir * seg;
      if (on) canvas.drawLine(cursor, next, paint);
      cursor = next;
      drawn += seg;
      on = !on;
    }
  }

  @override
  bool shouldRepaint(covariant StatLineChartPainter oldDelegate) =>
      !_seriesEquals(series, oldDelegate.series) ||
      !listEquals(xLabels, oldDelegate.xLabels) ||
      !listEquals(anomalies, oldDelegate.anomalies) ||
      anomalyColor != oldDelegate.anomalyColor ||
      labelColor != oldDelegate.labelColor ||
      labelStyle != oldDelegate.labelStyle ||
      labelFormatter != oldDelegate.labelFormatter ||
      labelEvery != oldDelegate.labelEvery;

  static bool _seriesEquals(List<StatLineSeries> a, List<StatLineSeries> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].color != b[i].color ||
          a[i].strokeWidth != b[i].strokeWidth ||
          a[i].dashed != b[i].dashed ||
          !listEquals(a[i].values, b[i].values)) {
        return false;
      }
    }
    return true;
  }
}
