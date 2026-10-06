import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
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
  const StatRangeBar({
    required this.range,
    required this.onChanged,
    super.key,
    this.padding,
  });

  final StatRange range;
  final ValueChanged<StatRangeSelection> onChanged;

  /// 外边距；null = 左右上 [FushiSpacingTokens.card]、下 0（与区块卡同一节奏）。
  final EdgeInsetsGeometry? padding;

  /// 粒度分段控件的最大宽度：宽屏下不把五段拉满整栏（每段会宽到像按钮条），
  /// 窄屏按可用宽度等分。
  static const double kSegmentsMaxWidth = 480;

  void _selectMode(StatRangeMode mode) => onChanged(
    StatRangeSelection(
      mode: mode,
      // 换粒度保留锚点：在「2026-05」里切到「周」落在 5 月那一周，而不是跳回本周。
      anchorKey: range.anchorKey == range.todayKey ? null : range.anchorKey,
    ),
  );

  /// 期间步进器「‹ 区间 ›」：与粒度分段同高（40）的紧凑胶囊。M3E 是扁平
  /// surfaceContainerHigh 底的小胶囊（不浮、无投影，曾是 56 高的悬浮大胶囊，
  /// 与旁边 40 高的分段按钮组一高一矮、两种样式）；Apple 保持无底一排。
  Widget _periodStepper(BuildContext context, FushiDesignTokens tokens) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const BoxConstraints button = BoxConstraints.tightFor(
      width: _kStepperHeight,
      height: _kStepperHeight,
    );
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIconButton(
          icon: Icons.chevron_left,
          tooltip: t.stat_range_previous,
          enabled: range.canGoPrevious,
          size: 20,
          padding: EdgeInsets.zero,
          constraints: button,
          onTap: () => onChanged(range.shifted(-1)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 88),
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: Text(
              formatStatRange(range),
              key: ValueKey<String>(formatStatRange(range)),
              textAlign: TextAlign.center,
              style: tokens.type.metadata.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        FushiIconButton(
          icon: Icons.chevron_right,
          tooltip: t.stat_range_next,
          enabled: range.canGoNext,
          size: 20,
          padding: EdgeInsets.zero,
          constraints: button,
          onTap: () => onChanged(range.shifted(1)),
        ),
      ],
    );
    if (isGlassDesign(context)) return row;
    final bool eink = isEinkTheme(context);
    return SizedBox(
      height: _kStepperHeight,
      child: DecoratedBox(
        key: const ValueKey<String>('stat-range-stepper'),
        decoration: ShapeDecoration(
          color: eink ? Colors.transparent : scheme.surfaceContainerHigh,
          shape: StadiumBorder(
            side: eink ? BorderSide(color: scheme.outline) : BorderSide.none,
          ),
        ),
        child: row,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 2026-10 统计中心重设计：粒度是分段控件（MD3 = M3 Expressive 连接式按钮
    // 组，Apple = 分段控件，经 [FushiSegmentedButton] 一处分派）。2026-10-06：
    // 粒度分段与期间步进器同一行、同高 40（此前分两行、步进器是悬浮大胶囊），
    // 窄屏摆不下时步进器折到下一行。
    return Padding(
      padding: padding ??
          EdgeInsets.fromLTRB(
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kSegmentsMaxWidth),
            child: FushiSegmentedButton<StatRangeMode>(
              key: const ValueKey<String>('stat-range-modes'),
              segments: <ButtonSegment<StatRangeMode>>[
                for (final StatRangeMode mode in StatRangeMode.values)
                  ButtonSegment<StatRangeMode>(
                    value: mode,
                    label: Text(
                      statRangeModeLabel(mode),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selected: <StatRangeMode>{range.mode},
              showSelectedIcon: false,
              onSelectionChanged: (Set<StatRangeMode> modes) {
                if (modes.isNotEmpty) _selectMode(modes.first);
              },
            ),
          ),
          _periodStepper(context, tokens),
          // 2026-10 体验优化：学习日历点某天会把范围切到单日，原先只能再点
          // 「月」+ 连按箭头才回得去。单日态下给一个显眼的「本月」快捷
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

/// 期间步进器的高：与 M3E 连接式分段按钮组（40）同高。
const double _kStepperHeight = 40;

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
  int totalMs = 0;
  for (final StatDayData d in data) {
    totalMs += d.ms;
  }
  return buildStatDailyDurationChartSection(
    context,
    data,
    title: t.stat_metric_time,
    subtitle: '${formatStatRange(range)} · ${formatStatTime(totalMs)}',
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
  // 2026-10 统计中心重设计：区块卡外框（[StatSectionCard]），区间进副标题。
  return StatSectionCard(
    title: t.stat_range_summary,
    subtitle: formatStatRange(range),
    icon: Icons.summarize_outlined,
    child: LayoutBuilder(
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
  // 2026-10 统计中心重设计：区块卡外框（[StatSectionCard]）。
  return StatSectionCard(
    title: t.stat_range_calendar,
    icon: Icons.calendar_month_outlined,
    child: StatContributionHeatmap(
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
  );
}
