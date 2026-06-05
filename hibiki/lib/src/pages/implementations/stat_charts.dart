import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 统计图表的每日数据点（阅读统计 / 视频统计共用）。
class StatDayData {
  StatDayData({required this.dateKey});
  final String dateKey;
  int chars = 0;
  int ms = 0;
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

  static String _formatMs(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes >= 60) return '${minutes ~/ 60}h';
    return '${minutes}m';
  }

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
        text: TextSpan(text: _formatMs(value), style: labelStyle),
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

/// 最近 N 天柱状图画笔（值为 [StatDayData.chars]）。阅读统计与视频统计共用。
class StatBarChartPainter extends CustomPainter {
  StatBarChartPainter({
    required this.data,
    required this.barColor,
    required this.barRadius,
    required this.labelColor,
    required this.labelStyle,
  });

  final List<StatDayData> data;
  final Color barColor;
  final Radius barRadius;
  final Color labelColor;
  final TextStyle labelStyle;

  static String _formatChars(int chars) {
    if (chars >= 10000) return '${(chars / 10000).toStringAsFixed(1)}万';
    if (chars >= 1000) return '${(chars / 1000).toStringAsFixed(1)}k';
    return chars.toString();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxChars =
        data.fold<int>(0, (prev, d) => d.chars > prev ? d.chars : prev);
    if (maxChars == 0) return;

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
      final value = (maxChars * i / yTicks).round();
      final y = chartHeight - (chartHeight * i / yTicks);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: _formatChars(value), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < data.length; i++) {
      final d = data[i];
      final x = leftPadding + i * step + gap / 2;
      final barHeight = (d.chars / maxChars) * chartHeight;

      if (d.chars > 0) {
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
      labelStyle != oldDelegate.labelStyle;
}
