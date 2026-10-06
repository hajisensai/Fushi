import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统计中心的范围条（对齐 Niratan 统计面板的「Range」）：日 / 周 / 月 / 年 / 全部
/// 粒度 + 上一段 / 下一段 + 当前区间文字。四个 tab 共用一份 [StatRangeSelection]
/// （[StatisticsCenterPage] 持有），切 tab 不丢范围。
///
/// 范围只驱动「分析」类区块（范围图表、所选范围汇总、趋势、速度、来源、按媒体
/// 列表）；顶部四张时段卡（今日 / 本周 / 本月 / 全部）与目标卡是**固定**的当下
/// 视图，不跟范围走——与 Niratan「Today / This Week 恒为当下」同一取舍。
class StatRangeBar extends StatelessWidget {
  const StatRangeBar({required this.range, required this.onChanged, super.key});

  final StatRange range;
  final ValueChanged<StatRangeSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final StatRangeMode mode in StatRangeMode.values)
            FushiSelectableChip(
              label: statRangeModeLabel(mode),
              selected: range.mode == mode,
              // 换粒度保留锚点：在「2026-05」里切到「周」落在 5 月那一周，
              // 而不是跳回本周。
              onSelected: (_) => onChanged(
                StatRangeSelection(
                  mode: mode,
                  anchorKey: range.anchorKey == range.todayKey
                      ? null
                      : range.anchorKey,
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIconButton(
                icon: Icons.chevron_left,
                tooltip: t.stat_range_previous,
                enabled: range.canGoPrevious,
                onTap: () => onChanged(range.shifted(-1)),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 96),
                child: Text(
                  formatStatRange(range),
                  textAlign: TextAlign.center,
                  style: tokens.type.metadata.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FushiIconButton(
                icon: Icons.chevron_right,
                tooltip: t.stat_range_next,
                enabled: range.canGoNext,
                onTap: () => onChanged(range.shifted(1)),
              ),
            ],
          ),
          // 2026-10 体验优化：学习日历点某天会把范围切到单日，原先只能再点
          // 「月」芯片 + 连按箭头才回得去。单日态下给一个显眼的「本月」快捷
          // 入口，一步回到当月（锚点跟随今日）。
          if (range.mode == StatRangeMode.day)
            FushiActionChip(
              key: const ValueKey<String>('stat-range-back-to-month'),
              label: t.stat_this_month,
              icon: Icons.calendar_month_outlined,
              onPressed: () => onChanged(const StatRangeSelection()),
            ),
        ],
      ),
    );
  }
}

String statRangeModeLabel(StatRangeMode mode) => switch (mode) {
  StatRangeMode.day => t.stat_range_mode_day,
  StatRangeMode.week => t.stat_range_mode_week,
  StatRangeMode.month => t.stat_range_mode_month,
  StatRangeMode.year => t.stat_range_mode_year,
  StatRangeMode.all => t.stat_all_time,
};

/// 区间文字：日 `2026-09-28`、周 `09-22 ~ 09-28`、月 `2026-09`、年 `2026`、
/// 全部 `2025-03-01 ~ 2026-09-28`。
String formatStatRange(StatRange range) {
  switch (range.mode) {
    case StatRangeMode.day:
      return range.fromKey;
    case StatRangeMode.week:
      return '${range.fromKey.substring(5)} ~ ${range.toKey.substring(5)}';
    case StatRangeMode.month:
      return range.fromKey.substring(0, 7);
    case StatRangeMode.year:
      return range.fromKey.substring(0, 4);
    case StatRangeMode.all:
      return range.fromKey == range.toKey
          ? range.fromKey
          : '${range.fromKey} ~ ${range.toKey}';
  }
}

/// 纯函数：把「dateKey → 当日合计」折成范围图表的柱：≤ 62 天逐日（空日补 0），
/// 更长按周（周一为桶键）/ 按月（`yyyy-MM`）汇总，粒度由 [StatRange.chartGrain]
/// 决定。输出按时间升序；只统计 [range] 内的日子。
List<StatDayData> buildStatRangeChartData(
  Map<String, StatDayData> byDay,
  StatRange range,
) {
  final List<String> keys = range.dayKeys;
  switch (range.chartGrain) {
    case StatRangeChartGrain.day:
      return <StatDayData>[
        for (final String key in keys)
          StatDayData(dateKey: key)
            ..chars = byDay[key]?.chars ?? 0
            ..ms = byDay[key]?.ms ?? 0,
      ];
    case StatRangeChartGrain.week:
    case StatRangeChartGrain.month:
      final bool weekly = range.chartGrain == StatRangeChartGrain.week;
      final Map<String, StatDayData> buckets = <String, StatDayData>{};
      for (final String key in keys) {
        final String bucket = weekly
            ? FushiDatabase.statDateKeyPlusDays(
                key,
                -(FushiDatabase.statDateKeyToDay(key).weekday -
                    DateTime.monday),
              )
            : key.substring(0, 7);
        final StatDayData data = buckets.putIfAbsent(
          bucket,
          () => StatDayData(
            dateKey: bucket,
            label: weekly ? bucket.substring(5) : bucket.substring(2),
          ),
        );
        final StatDayData? day = byDay[key];
        if (day == null) continue;
        data.chars += day.chars;
        data.ms += day.ms;
      }
      return buckets.values.toList();
  }
}

/// 纯函数：把日面行按 dateKey 汇总（范围图表 / 日历热力图共用的输入形状）。
Map<String, StatDayData> sumStatDaysByKey(Iterable<StatFact> rows) {
  final Map<String, StatDayData> byDay = <String, StatDayData>{};
  for (final StatFact r in rows) {
    final StatDayData day = byDay.putIfAbsent(
      r.dateKey,
      () => StatDayData(dateKey: r.dateKey),
    );
    day.chars += r.chars;
    day.ms += r.ms;
  }
  return byDay;
}

/// 纯函数：计数面事件（dateKey, 次数）落在 [range] 内的合计（查词 / 制卡 /
/// 收藏按范围求和，与 [bucketActivityByDateKey] 同一批事件）。
int sumStatEventsInRange(Iterable<(String, int)> events, StatRange range) {
  int total = 0;
  for (final (String dateKey, int count) in events) {
    if (range.contains(dateKey)) total += count;
  }
  return total;
}

/// 范围时长柱状图：标题 = 「时长 · 区间」，柱粒度随范围自动变（日 / 周 / 月），
/// 横轴标签按柱数稀疏到约 7 个，一年 53 根周柱也不糊成一片。
Widget buildStatRangeChartSection(
  BuildContext context,
  StatRange range,
  Map<String, StatDayData> byDay,
) {
  final List<StatDayData> data = buildStatRangeChartData(byDay, range);
  return buildStatDailyDurationChartSection(
    context,
    data,
    title: '${t.stat_metric_time} · ${formatStatRange(range)}',
    labelEvery: math.max(1, (data.length / 7).ceil()),
  );
}

/// 「所选范围」汇总卡：时长 / 字数 / 活跃天数 / 日均时长（+ 调用方给的额外行，
/// 如阅读速度、查词数）。数字全部出自 [range] 内的日面。
Widget buildStatRangeSummary(
  BuildContext context,
  StatRange range,
  Map<String, StatDayData> byDay, {
  List<StatSummaryLine> extraLines = const <StatSummaryLine>[],
}) {
  int chars = 0;
  int ms = 0;
  int activeDays = 0;
  byDay.forEach((String key, StatDayData d) {
    if (!range.contains(key)) return;
    chars += d.chars;
    ms += d.ms;
    if (d.chars > 0 || d.ms > 0) activeDays++;
  });
  final int avgMs = activeDays == 0 ? 0 : ms ~/ activeDays;
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final List<(String, String)> cells = <(String, String)>[
    (t.stat_metric_time, formatStatTime(ms)),
    (t.stat_metric_chars, formatStatChars(chars)),
    (t.stat_range_active_days, t.stat_format_days(n: activeDays)),
    (t.stat_daily_average, formatStatTime(avgMs)),
    for (final StatSummaryLine l in extraLines) (l.label ?? '', l.value),
  ];
  return Padding(
    padding: EdgeInsets.fromLTRB(
      tokens.spacing.card,
      tokens.spacing.card,
      tokens.spacing.card,
      tokens.spacing.card,
    ),
    child: FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${t.stat_range_summary} · ${formatStatRange(range)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: tokens.spacing.gap),
          // 等宽列网格（2026-10-04 用户截图）：原先是按内容宽度排的 Wrap，每行
          // 能塞几个取决于数字长短——手机上第一行两格、第二行两格、第三行三格，
          // 列不对齐，像随手堆的。改成手机 2 列、宽屏 4 列的等宽格，数字过长时
          // 在格内等比缩小而不是换行或撑出。
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double gap = tokens.spacing.card;
              final int columns = constraints.maxWidth >= 520 ? 4 : 2;
              final double cellWidth =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  for (final (String label, String value) in cells)
                    SizedBox(
                      width: cellWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              value,
                              maxLines: 1,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.type.metadata.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}

/// 学习日历（Niratan「Reading Calendar」）：本域的逐日热力图，格子深浅 = 当日
/// 学习时长（只有字数的日子如实算最浅一档）；点某天 → 范围切到那一天。
Widget buildStatRangeCalendarSection(
  BuildContext context, {
  required Map<String, StatDayData> byDay,
  required DateTime now,
  required ValueChanged<String> onDaySelected,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final Map<String, int> values = <String, int>{
    for (final MapEntry<String, StatDayData> e in byDay.entries)
      if (e.value.ms > 0 || e.value.chars > 0)
        e.key: math.max(e.value.ms ~/ 1000, 1),
  };
  return Padding(
    // 底部留一个 card 间距：此前为 0，热力图最后一行与下方「时长 · 区间」
    // 图表标题贴死（2026-10-04 用户截图）。
    padding: EdgeInsets.all(tokens.spacing.card),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          t.stat_range_calendar,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SizedBox(height: tokens.spacing.gap),
        StatContributionHeatmap(
          valueByDateKey: values,
          now: now,
          baseColor: tokens.surfaces.primary,
          emptyColor: statHeatmapEmptyColors(context).$1,
          emptyBorderColor: statHeatmapEmptyColors(context).$2,
          valueLabel: (String dateKey, int _) {
            final StatDayData? d = byDay[dateKey];
            final String day = formatStatHeatmapDay(dateKey);
            if (d == null) return day;
            final List<String> parts = <String>[
              day,
              if (d.ms > 0) formatStatTime(d.ms),
              if (d.chars > 0) formatStatChars(d.chars),
            ];
            return parts.join(' · ');
          },
          onDaySelected: (String dateKey, int _) => onDaySelected(dateKey),
        ),
      ],
    ),
  );
}
