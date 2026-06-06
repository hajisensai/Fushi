import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 统计图表的每日数据点（阅读统计 / 视频统计共用）。
class StatDayData {
  StatDayData({required this.dateKey});
  final String dateKey;
  int chars = 0;
  int ms = 0;
}

/// 取 [StatDayData.chars] 作图表值（阅读统计默认）。用顶层静态 tear-off 而非
/// 闭包，使 [StatBarChartPainter.shouldRepaint] 的函数相等比较稳定（每帧新建的
/// 闭包恒不相等会导致每帧重绘）。
int statCharsValue(StatDayData d) => d.chars;

/// 取 [StatDayData.ms] 作图表值（视频统计：删字数后以观看时长为准）。
int statMsValue(StatDayData d) => d.ms;

/// 把字数格式化为坐标轴标签（万 / k / 原值）。
String formatStatCharsAxis(int chars) {
  if (chars >= 10000) return '${(chars / 10000).toStringAsFixed(1)}万';
  if (chars >= 1000) return '${(chars / 1000).toStringAsFixed(1)}k';
  return chars.toString();
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
  });

  final List<StatDayData> data;
  final Color barColor;
  final Radius barRadius;
  final Color labelColor;
  final TextStyle labelStyle;
  final int Function(StatDayData) valueOf;
  final String Function(int) labelFormatter;

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
            text: d.dateKey.substring(5), // MM-DD
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
      labelFormatter != oldDelegate.labelFormatter;
}
