import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart' show LocaleSettings;
import 'package:fushi/src/pages/implementations/stat_hourly_breakdown.dart';

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

/// 使用「万」进制（10^4 分组）的语言 → 其倍率单位；非 CJK 语言返回 null（走
/// 国际千进制 K / M）。
///
/// BUG-935 当年把「万」当成跨语言通用倍率补进了 13 种非 CJK 语言的译文，于是
/// 英文界面显示「6.8万 characters」——这个数对英文读者既不是 68000 也不是任何
/// 可读写法。倍率分组是**语言属性**，不是可翻译的文案，所以它属于这里而不属于
/// i18n 词条。
String? statMyriadUnit(String languageTag) {
  final String tag = languageTag.toLowerCase();
  if (tag == 'ja' || tag.startsWith('ja-')) return '万';
  if (tag == 'ko' || tag.startsWith('ko-')) return '만';
  if (tag == 'zh' || tag.startsWith('zh-')) {
    const List<String> traditional = <String>['hant', 'hk', 'tw', 'mo'];
    return traditional.any(tag.contains) ? '萬' : '万';
  }
  return null;
}

/// 一位小数，整数去掉多余的 `.0`（`6.8` / `68`）。
String _compactDecimal(num v) {
  final String s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// 大数紧凑写法，按语言选进制：CJK 走万进制（`6.8万`），其余语言走千进制
/// （`68K` / `1.2M`）。
///
/// 阈值统一取 10000：两种进制在此之下都显示原值，所以「不足一万显示全数字」这条
/// 口径对所有语言一致，同一张卡上不会一半缩写一半不缩写。
String formatCompactCount(int value, String languageTag) {
  if (value < 10000) return value.toString();
  final String? myriad = statMyriadUnit(languageTag);
  if (myriad != null) return '${_compactDecimal(value / 10000)}$myriad';
  if (value >= 1000000) return '${_compactDecimal(value / 1000000)}M';
  return '${_compactDecimal(value / 1000)}K';
}

/// 当前界面语言下的紧凑字数（坐标轴标签用；带「characters」单位的卡片文案见
/// `formatStatChars`）。
String formatStatCharsAxis(int chars) =>
    formatCompactCount(chars, LocaleSettings.currentLocale.languageTag);

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
  if (ms >= 3600000) {
    // BUG-892：非整点小时保留一位小数。旧代码 `ms ~/ 3600000` 向下取整，maxMs>1h 时
    // 相邻刻度（如 2.0h 与 2.5h）都塌成 "2h" → 纵轴出现 "…2h 2h" 重复标签。
    final double h = ms / 3600000;
    return h == h.truncateToDouble()
        ? '${h.toInt()}h'
        : '${h.toStringAsFixed(1)}h';
  }
  if (ms >= 60000) return '${ms ~/ 60000}m';
  if (ms > 0) return '${ms ~/ 1000}s';
  return '0';
}

/// 一条纵轴的完整刻度表：等距刻度值（0 起、末项 ≥ 数据最大值）+ 一一对应的标签。
///
/// 旧实现把 `maxValue` 直接四等分再让每个刻度**各自**挑单位，于是同一条轴上出现
/// `2.9h / 2.2h / 1.5h / 43m` 这种非整数 + 混单位的刻度。刻度是整条轴的属性而不是
/// 单个刻度的属性；把它收成一个对象后，「步长取整」和「整轴一个单位」都变成普通
/// 情况，标签函数里的单位分支随之消失（刻度恒为步长的整数倍 → 标签恒为整数）。
class StatAxisScale {
  StatAxisScale({required this.ticks, required this.labels})
      : assert(ticks.length == labels.length, '刻度值与标签必须一一对应');

  /// 升序刻度值，首项恒为 0，末项 ≥ 数据最大值（柱高也按末项归一，柱子因此永远
  /// 不会顶破最高刻度线）。
  final List<int> ticks;

  /// 与 [ticks] 同序的标签，整条轴共用一个单位。
  final List<String> labels;

  /// 轴顶 = 最高刻度值。恒 > 0。
  int get max => ticks.last;
}

/// 纵轴刻度数（0 刻度之外的格数）。
const int _kAxisTickCount = 4;

/// 时长纵轴的候选步长（毫秒）：秒 / 分 / 小时里的自然刻度，每个都是其单位的整数
/// 倍——这保证标签整除后不留小数。
const List<int> _kDurationAxisSteps = <int>[
  1000, 5000, 10000, 15000, 30000, // 秒
  60000, 120000, 300000, 600000, 900000, 1800000, // 分
  3600000, 7200000, 10800000, 21600000, 43200000, 86400000, // 时
];

/// 从候选步长里取第一个能让 `step * _kAxisTickCount` 盖住 [maxValue] 的；候选都
/// 不够时按 [fallbackUnit] 的整数倍向上取整（时长轴 = 整天）。
int _pickAxisStep(int maxValue, List<int> candidates, int fallbackUnit) {
  final int target = maxValue <= 0 ? 1 : maxValue;
  for (final int step in candidates) {
    if (step * _kAxisTickCount >= target) return step;
  }
  return fallbackUnit * (target / (fallbackUnit * _kAxisTickCount)).ceil();
}

/// 单位由**步长**而非轴顶决定：步长是整小时就整轴用 h，是整分就整轴用 m，否则 s。
/// 刻度值都是步长的整数倍，所以每个标签都能整除到整数（不再有 `2.9h`）。
String _durationAxisLabel(int ms, int step) {
  if (ms == 0) return '0';
  if (step >= 3600000) return '${ms ~/ 3600000}h';
  if (step >= 60000) return '${ms ~/ 60000}m';
  return '${ms ~/ 1000}s';
}

/// 时长纵轴刻度表（最近 N 天时长图 / 今日按小时图共用）。
StatAxisScale statDurationAxisScale(int maxMs) {
  final int step = _pickAxisStep(maxMs, _kDurationAxisSteps, 86400000);
  return StatAxisScale(
    ticks: <int>[for (int i = 0; i <= _kAxisTickCount; i++) step * i],
    labels: <String>[
      for (int i = 0; i <= _kAxisTickCount; i++)
        _durationAxisLabel(step * i, step),
    ],
  );
}

/// 计数纵轴的 nice 步长：1 / 2 / 5 × 10^n 里第一个能盖住 [maxValue] 的。
int _niceCountStep(int maxValue) {
  final double raw = (maxValue <= 0 ? 1 : maxValue) / _kAxisTickCount;
  int pow10 = 1;
  while (pow10 * 10 <= raw) {
    pow10 *= 10;
  }
  for (final int m in const <int>[1, 2, 5]) {
    if (pow10 * m >= raw) return pow10 * m;
  }
  return pow10 * 10;
}

/// 计数纵轴刻度表（字数等）。标签走当前语言的紧凑写法（[formatStatCharsAxis]）。
StatAxisScale statCountAxisScale(int maxValue) {
  final int step = _niceCountStep(maxValue);
  return StatAxisScale(
    ticks: <int>[for (int i = 0; i <= _kAxisTickCount; i++) step * i],
    labels: <String>[
      for (int i = 0; i <= _kAxisTickCount; i++)
        i == 0 ? '0' : formatStatCharsAxis(step * i),
    ],
  );
}

/// 今日按小时柱状图的一条**堆叠带**：24 小时的毫秒值 + 填充色。
///
/// 单带 = 旧的单色柱（视频统计：观看时长没有阅读面之分）；多带 = 同一根柱子自下
/// 而上按列表序堆叠（阅读统计按 format 分带）。「一根柱子只有一种颜色」在这里是
/// 「只有一条带」这个普通情况，不是单独的分支。
class StatHourlyBand {
  const StatHourlyBand({required this.values, required this.color});

  /// 0-23 时的毫秒值。长度不足的位置按 0 处理。
  final List<int> values;
  final Color color;
}

/// 今日按小时柱状图画笔（0-23 小时，值为毫秒）。阅读统计与视频统计共用。
class StatHourlyChartPainter extends CustomPainter {
  StatHourlyChartPainter({
    required this.bands,
    required this.barRadius,
    required this.labelColor,
    required this.labelStyle,
  });

  final List<StatHourlyBand> bands;
  final Radius barRadius;
  final Color labelColor;
  final TextStyle labelStyle;

  static int _valueAt(StatHourlyBand band, int hour) =>
      hour < band.values.length ? band.values[hour] : 0;

  /// 某小时所有带的合计（决定柱高与纵轴上限）。
  int totalAt(int hour) => bands.fold<int>(
      0, (int sum, StatHourlyBand band) => sum + _valueAt(band, hour));

  @override
  void paint(Canvas canvas, Size size) {
    if (bands.isEmpty) return;

    final List<int> totals =
        List<int>.generate(kStatHourlyBuckets, totalAt, growable: false);
    final maxMs = totals.fold<int>(0, (prev, ms) => ms > prev ? ms : prev);
    if (maxMs == 0) return;

    const bottomPadding = 20.0;
    const leftPadding = 32.0;
    final chartHeight = size.height - bottomPadding;
    final chartWidth = size.width - leftPadding;
    final step = chartWidth / kStatHourlyBuckets;
    final barWidth = step * 0.7;
    final gap = step * 0.15;

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

    // 与最近 N 天时长图同一套刻度（[statDurationAxisScale]）：整轴一个单位、刻度
    // 取整、柱高按轴顶归一。
    final StatAxisScale scale = statDurationAxisScale(maxMs);
    final int axisMax = scale.max;
    for (int i = 0; i < scale.ticks.length; i++) {
      final y = chartHeight - (chartHeight * scale.ticks[i] / axisMax);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: scale.labels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < kStatHourlyBuckets; i++) {
      final x = leftPadding + i * step + gap;
      final total = totals[i];

      if (total > 0) {
        final barHeight = (total / axisMax) * chartHeight;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, chartHeight - barHeight, barWidth, barHeight),
          barRadius,
        );
        // 整根柱子先剪成圆角，各段按普通矩形填进去——圆角只在柱子两端出现，不必
        // 为「首段 / 末段 / 单段」写三套 RRect 分支。
        canvas.save();
        canvas.clipRRect(rect);
        double segmentBottom = chartHeight;
        int accumulated = 0;
        for (final StatHourlyBand band in bands) {
          final int value = _valueAt(band, i);
          if (value <= 0) continue;
          accumulated += value;
          // 用累计值算上沿而非逐段累加高度：避免每段各取一次舍入后段间出现缝隙。
          final double segmentTop =
              chartHeight - (accumulated / axisMax) * chartHeight;
          canvas.drawRect(
            Rect.fromLTWH(x, segmentTop, barWidth, segmentBottom - segmentTop),
            Paint()..color = band.color,
          );
          segmentBottom = segmentTop;
        }
        canvas.restore();
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
      !_bandsEqual(bands, oldDelegate.bands) ||
      barRadius != oldDelegate.barRadius ||
      labelColor != oldDelegate.labelColor ||
      labelStyle != oldDelegate.labelStyle;

  static bool _bandsEqual(List<StatHourlyBand> a, List<StatHourlyBand> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].color != b[i].color || !listEquals(a[i].values, b[i].values)) {
        return false;
      }
    }
    return true;
  }
}

/// 最近 N 天柱状图画笔。阅读统计默认画字数（[statCharsValue]），视频统计删字数后
/// 画观看时长（[statMsValue]）。[valueOf] / [axisScaleOf] 用顶层静态 tear-off
/// 传入，使 [shouldRepaint] 的函数相等比较稳定。
class StatBarChartPainter extends CustomPainter {
  StatBarChartPainter({
    required this.data,
    required this.barColor,
    required this.barRadius,
    required this.labelColor,
    required this.labelStyle,
    this.valueOf = statCharsValue,
    this.axisScaleOf = statCountAxisScale,
    this.labelOf = statDayLabel,
  });

  final List<StatDayData> data;
  final Color barColor;
  final Radius barRadius;
  final Color labelColor;
  final TextStyle labelStyle;
  final int Function(StatDayData) valueOf;

  /// 数据最大值 → 整条纵轴的刻度表（[statCountAxisScale] / [statDurationAxisScale]）。
  final StatAxisScale Function(int) axisScaleOf;

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

    // 网格线与柱高都按轴顶（最高刻度）归一，而不是按数据最大值——否则取整后的
    // 最高刻度线会落在画布外，最高的那根柱子也会顶破它。
    final StatAxisScale scale = axisScaleOf(maxValue);
    final int axisMax = scale.max;
    for (int i = 0; i < scale.ticks.length; i++) {
      final y = chartHeight - (chartHeight * scale.ticks[i] / axisMax);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: scale.labels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < data.length; i++) {
      final d = data[i];
      final x = leftPadding + i * step + gap / 2;
      final value = valueOf(d);
      final barHeight = (value / axisMax) * chartHeight;

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
      axisScaleOf != oldDelegate.axisScaleOf ||
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
