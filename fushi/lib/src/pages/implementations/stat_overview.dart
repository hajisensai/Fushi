import 'package:flutter/material.dart';
import 'package:fushi/src/pages/implementations/stat_ring.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/stat_summary.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 统计中心总览（2026-10 重设计）的展示件：媒体类型筛选、关键指标区（目标 +
/// 四张指标卡）与空数据态。数据层一行不碰——这里只消费页面经 [loadStatFacts]
/// 取回的日面 / 会话，按筛选切片、按 [StatWindow] 取窗口。

/// 总览的媒体类型筛选（全部 / 阅读 / 观看 / 游戏）。
///
/// 「全部」= 跨域（与三个域 tab 之和恒等，见 `StatCounterFacts`）；其余三档
/// 与对应域 tab 是同一份切片判据：日面 / 会话按 `mediaKind`，计数面按
/// [StatSourceKind]（[source]）。
enum StatMediaFilter { all, book, video, game }

extension StatMediaFilterX on StatMediaFilter {
  /// 计数面（查词 / 制卡 / 收藏）的来源；null = 跨域。
  StatSourceKind? get source => switch (this) {
    StatMediaFilter.all => null,
    StatMediaFilter.book => StatSourceKind.book,
    StatMediaFilter.video => StatSourceKind.video,
    StatMediaFilter.game => StatSourceKind.game,
  };

  /// 某个媒体种类（`kActivityMedia*`）是否落在本档里。
  bool includesKind(String mediaKind) => switch (this) {
    StatMediaFilter.all => true,
    StatMediaFilter.book => mediaKind == kActivityMediaBook,
    StatMediaFilter.video => mediaKind == kActivityMediaVideo,
    StatMediaFilter.game => mediaKind == kActivityMediaGame,
  };

  String get label => switch (this) {
    StatMediaFilter.all => t.home_filter_all,
    StatMediaFilter.book => t.home_filter_read,
    StatMediaFilter.video => t.home_filter_watch,
    StatMediaFilter.game => t.home_filter_game,
  };

  IconData get icon => switch (this) {
    StatMediaFilter.all => Icons.apps_rounded,
    StatMediaFilter.book => Icons.menu_book_outlined,
    StatMediaFilter.video => Icons.movie_outlined,
    StatMediaFilter.game => Icons.sports_esports_outlined,
  };
}

/// 纯函数：按筛选切日面行。
List<StatFact> filterStatFacts(
  Iterable<StatFact> daily,
  StatMediaFilter filter,
) => <StatFact>[
  for (final StatFact f in daily)
    if (filter.includesKind(f.mediaKind)) f,
];

/// 纯函数：按筛选切会话流（保持原有的倒序）。
List<StudySession> filterStudySessions(
  Iterable<StudySession> sessions,
  StatMediaFilter filter,
) => <StudySession>[
  for (final StudySession s in sessions)
    if (filter.includesKind(s.mediaKind)) s,
];

/// 总览关键指标（今日 / 本周时长、今日 / 本周字数、连续天数、近 7 日活跃天数）。
@immutable
class StatOverviewKpis {
  const StatOverviewKpis({
    required this.todayMs,
    required this.weekMs,
    required this.prevWeekMs,
    required this.todayChars,
    required this.weekChars,
    required this.streak,
    required this.activeDaysLast7,
  });

  final int todayMs;
  final int weekMs;
  final int prevWeekMs;
  final int todayChars;
  final int weekChars;
  final int streak;
  final int activeDaysLast7;
}

/// 纯函数：关键指标。窗口一律出自 [w]（本轮加载的唯一窗口，BUG-2219），
/// 连续天数与阅读页同一个 [computeReadingStreak]（这里喂的是筛选后的活跃日）。
StatOverviewKpis computeStatOverviewKpis(
  Iterable<StatFact> daily,
  StatWindow w,
) {
  int todayMs = 0;
  int weekMs = 0;
  int prevWeekMs = 0;
  int todayChars = 0;
  int weekChars = 0;
  final Set<String> active = <String>{};
  for (final StatFact f in daily) {
    if (f.ms <= 0 && f.chars <= 0) continue;
    active.add(f.dateKey);
    if (w.isToday(f.dateKey)) {
      todayMs += f.ms;
      todayChars += f.chars;
    }
    if (w.inWeek(f.dateKey)) {
      weekMs += f.ms;
      weekChars += f.chars;
    }
    if (w.inPrevWeek(f.dateKey)) prevWeekMs += f.ms;
  }
  int activeDaysLast7 = 0;
  for (final String key in w.lastDayKeys(7)) {
    if (active.contains(key)) activeDaysLast7++;
  }
  return StatOverviewKpis(
    todayMs: todayMs,
    weekMs: weekMs,
    prevWeekMs: prevWeekMs,
    todayChars: todayChars,
    weekChars: weekChars,
    streak: computeReadingStreak(active, w.now),
    activeDaysLast7: activeDaysLast7,
  );
}

/// 媒体类型筛选条：一行可聚焦的 chip（键盘 / 手柄方向键遍历、Enter 选中）。
class StatMediaFilterBar extends StatelessWidget {
  const StatMediaFilterBar({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final StatMediaFilter selected;
  final ValueChanged<StatMediaFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Semantics(
      container: true,
      label: t.stat_center_media_filter,
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final StatMediaFilter f in StatMediaFilter.values)
            FushiSelectableChip(
              key: ValueKey<String>('stat-media-filter-${f.name}'),
              label: f.label,
              leadingIcon: f.icon,
              selected: f == selected,
              onSelected: (_) => onChanged(f),
            ),
        ],
      ),
    );
  }
}

/// 总览宽屏判据（内容宽度）：≥ 此值时趋势区块与明细区块左右两栏并排，否则
/// 单栏自上而下。比 [kStatLandscapeMinWidth] 宽一档：两栏里左栏要放下 4 列的
/// 所选范围卡、右栏要放下两列时段卡。
const double kStatOverviewWideMinWidth = 840;

/// 关键指标区的宽屏判据（内容宽度）：目标卡与 2×2 指标卡并排；更窄时上下叠。
const double kStatOverviewHeroWideMinWidth = 720;

/// 总览关键指标区：每日目标（环形进度，可点进目标编辑）+ 四张指标卡。
///
/// 目标分子由调用方传入（页面经 `studyGoalCharsForDay` 用完整日面算——目标是
/// 跨域的「每日学习目标」，不随媒体筛选变口径）。
class StatOverviewHero extends StatelessWidget {
  const StatOverviewHero({
    required this.kpis,
    required this.goalChars,
    required this.goalProgressChars,
    super.key,
    this.onEditGoal,
  });

  final StatOverviewKpis kpis;

  /// 每日目标字数；≤ 0 = 未设。
  final int goalChars;

  /// 今日计入目标的字数。
  final int goalProgressChars;

  final VoidCallback? onEditGoal;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final StatChartColors colors = statChartColorsOf(context);
    final double gap = tokens.spacing.gap + tokens.spacing.gap / 2;
    final String weekDelta = formatWeekOverWeekDelta(
      kpis.weekMs,
      kpis.prevWeekMs,
    );
    final Color? weekDeltaColor = kpis.prevWeekMs == 0
        ? null
        : (kpis.weekMs >= kpis.prevWeekMs ? colors.up : colors.down);
    final List<Widget> tiles = <Widget>[
      _StatKpiTile(
        key: const ValueKey<String>('stat-kpi-today-time'),
        icon: Icons.today_outlined,
        label: t.stat_overview_today_time,
        value: formatStatTime(kpis.todayMs),
      ),
      _StatKpiTile(
        key: const ValueKey<String>('stat-kpi-week-time'),
        icon: Icons.date_range_outlined,
        label: t.stat_overview_week_time,
        value: formatStatTime(kpis.weekMs),
        caption: t.stat_overview_vs_last_week(delta: weekDelta),
        captionColor: weekDeltaColor,
      ),
      _StatKpiTile(
        key: const ValueKey<String>('stat-kpi-today-chars'),
        icon: Icons.translate_outlined,
        label: t.stat_overview_today_chars,
        value: formatStatChars(kpis.todayChars),
        caption: t.stat_overview_week_chars(
          value: formatStatChars(kpis.weekChars),
        ),
      ),
      _StatKpiTile(
        key: const ValueKey<String>('stat-kpi-streak'),
        icon: Icons.local_fire_department_outlined,
        label: t.stat_streak,
        value: t.stat_format_days(n: kpis.streak),
        caption: t.stat_overview_active_days(n: kpis.activeDaysLast7),
      ),
    ];
    final Widget grid = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < tiles.length; i += 2) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: tiles[i]),
                SizedBox(width: gap),
                Expanded(child: tiles[i + 1]),
              ],
            ),
          ),
        ],
      ],
    );
    final Widget goal = _StatGoalPanel(
      goalChars: goalChars,
      progressChars: goalProgressChars,
      onTap: onEditGoal,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth >= kStatOverviewHeroWideMinWidth) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 2, child: goal),
                  SizedBox(width: gap),
                  Expanded(flex: 3, child: grid),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              goal,
              SizedBox(height: gap),
              grid,
            ],
          );
        },
      ),
    );
  }
}

/// 一张关键指标卡：色调图标徽章 + 标签 + 大号数值（变化时淡入换位）+ 说明行。
class _StatKpiTile extends StatelessWidget {
  const _StatKpiTile({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
    this.caption,
    this.captionColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? caption;
  final Color? captionColor;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final StatChartColors colors = statChartColorsOf(context);
    final String? cap = caption;
    return FushiCard(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Semantics(
        container: true,
        label: label,
        value: value,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                _StatIconBadge(icon: icon, color: colors.series),
                SizedBox(width: tokens.spacing.gap),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: AlignmentDirectional.centerStart,
                children: <Widget>[...previous, if (current != null) current],
              ),
              child: FittedBox(
                key: ValueKey<String>(value),
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  value,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
            if (cap != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                cap,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata.copyWith(
                  color: captionColor ?? scheme.onSurfaceVariant,
                  fontWeight: captionColor == null ? null : FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 指标卡左上角的色调图标徽章（MD3 = 主色 12% 圆底；Apple 同一做法用强调色）。
class _StatIconBadge extends StatelessWidget {
  const _StatIconBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: FushiIcon(icon, size: 18, color: color),
    );
  }
}

/// 每日目标面板：设了目标 = 环形进度（进场时弧从 0 长到当前值）+ 进度文案；
/// 未设 = 引导文案。整卡可点进目标编辑（与页头旗标按钮同一个入口）。
class _StatGoalPanel extends StatelessWidget {
  const _StatGoalPanel({
    required this.goalChars,
    required this.progressChars,
    required this.onTap,
  });

  final int goalChars;
  final int progressChars;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final StatChartColors colors = statChartColorsOf(context);
    final Widget body;
    if (goalChars <= 0) {
      body = Row(
        children: <Widget>[
          _StatIconBadge(icon: Icons.flag_outlined, color: colors.series),
          SizedBox(width: tokens.spacing.card),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t.stat_overview_goal_unset,
                  style: statSectionTitleStyle(context),
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.stat_overview_goal_unset_hint,
                  style: tokens.type.metadata.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                Text(
                  t.stat_goal_set,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.series,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      final double fraction = (progressChars / goalChars).clamp(0.0, 1.0);
      final bool reached = progressChars >= goalChars;
      final Color ringColor = reached ? colors.reached : colors.series;
      body = Row(
        children: <Widget>[
          StatChartEntrance(
            replayKey: fraction,
            builder: (BuildContext context, double progress) => StatRing(
              fraction: fraction * progress,
              color: ringColor,
              trackColor: ringColor.withValues(alpha: 0.16),
              value: '${(fraction * 100 * progress).round()}%',
              caption: t.stat_goal,
              size: 104,
              strokeWidth: 10,
            ),
          ),
          SizedBox(width: tokens.spacing.card),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(t.stat_goal, style: statSectionTitleStyle(context)),
                SizedBox(height: tokens.spacing.gap / 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    t.stat_goal_progress(read: progressChars, goal: goalChars),
                    maxLines: 1,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  reached
                      ? t.stat_goal_reached
                      : t.stat_overview_goal_remaining(
                          value: formatStatChars(goalChars - progressChars),
                        ),
                  style: tokens.type.metadata.copyWith(
                    color: reached ? colors.reached : scheme.onSurfaceVariant,
                    fontWeight: reached ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return FushiCard(
      key: const ValueKey<String>('stat-overview-goal'),
      onTap: onTap,
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Center(child: body),
    );
  }
}

/// 总览空数据态：当前筛选下一条学习记录都没有时，取代图表 / 时段 / 会话区块。
class StatOverviewEmpty extends StatelessWidget {
  const StatOverviewEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: FushiCard(
        key: const ValueKey<String>('stat-overview-empty'),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.card,
          vertical: tokens.spacing.card * 2,
        ),
        child: FushiPlaceholderMessage(
          icon: Icons.insights_outlined,
          message: t.stat_overview_empty,
        ),
      ),
    );
  }
}
