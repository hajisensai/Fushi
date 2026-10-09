import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/implementations/stat_ring.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/stat_summary.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

/// 统计中心的统一版式件（2026-10 重设计）：总览与阅读 / 观看 / 游戏三个域页
/// 共用同一套页面骨架、关键指标卡、目标面板、区块小标题与空数据态——各页只
/// 装配自己域的数据，排布、间距、宽窄判据与进场动效只在这里写一次。
///
/// 数据层一行不碰：这里只消费页面经 `loadStatFacts` 取回、按域切好的日面。

/// 统计页宽屏判据（内容宽度）：≥ 此值时趋势区块与明细区块左右两栏（3:2）并排，
/// 否则单栏自上而下。两栏里左栏要放下 4 列的所选范围卡、右栏要放下两列时段卡。
const double kStatDashboardWideMinWidth = 840;

/// 关键指标区的宽屏判据（内容宽度）：目标面板与指标卡并排、无目标面板时四张
/// 指标卡一排；更窄时上下叠 / 2×2。
const double kStatHeroWideMinWidth = 720;

/// 统计页主体排布。信息架构自上而下：
///
///  1. [header] 页内筛选（总览的媒体类型 chip；域页没有）；
///  2. [hero] 关键指标区（[StatHero]）；
///  3. [trend] 趋势：时间窗口分段控件 + 日期翻页（`StatRangeBar`）→ 范围时长图
///     → 所选范围卡 → 学习日历 → 「分析」折叠；
///  4. [details] 明细：时段卡（点开 = 该时段按作品的明细 sheet）→ 最近会话 →
///     按作品列表的小标题，再接 [detailSlivers]（按作品长列表，惰性构建）。
///
/// 宽屏（内容 ≥ [kStatDashboardWideMinWidth]）1、2 通栏，3 / 4 左右两栏（3:2，
/// 同一条滚动视图——两栏一起滚、长列表照样惰性）；窄屏单栏自上而下。每块按顺序
/// 错峰进场（[FushiStaggeredEntrance]），两栏从同一个序号起数——同时落位；长列表
/// 的行在滚动中出现，不逐行淡入。[replayKey] 变化（换筛选）时重播一次。
/// [emptyState] 非空时取代 3 / 4。
class StatDashboardBody extends StatelessWidget {
  const StatDashboardBody({
    required this.tail,
    super.key,
    this.header,
    this.hero,
    this.replayKey,
    this.trend = const <Widget>[],
    this.details = const <Widget>[],
    this.detailSlivers = const <Widget>[],
    this.emptyState,
  });

  final Widget? header;
  final Widget? hero;
  final List<Widget> trend;
  final List<Widget> details;

  /// 明细栏末尾的 sliver（按作品列表等长列表）。
  final List<Widget> detailSlivers;
  final Widget? emptyState;

  /// 滚动视图末尾的 sliver（底部安全区留白，见 `buildStatTailSliver`）。
  final Widget tail;
  final Object? replayKey;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      replayKey: replayKey,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= kStatDashboardWideMinWidth;
          int order = 0;
          Widget box(Widget child, int index) => SliverToBoxAdapter(
            child: FushiStaggeredEntrance(index: index, child: child),
          );
          final List<Widget> slivers = <Widget>[
            // 正文铺到浮动页头底下（[FushiPageScaffold] 默认）：首屏让开页头，
            // 往下滚时内容滚进页头胶囊底下（统计中心 2026-10-06 截图：页头
            // 下沿硬切 KPI 卡）。不在浮动页头下时这段 padding 是状态栏 / 0。
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.paddingOf(context).top),
            ),
            if (header case final Widget h)
              box(
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.card,
                    tokens.spacing.gap,
                    tokens.spacing.card,
                    0,
                  ),
                  child: h,
                ),
                order++,
              ),
            if (hero case final Widget h) box(h, order++),
          ];
          final Widget? empty = emptyState;
          if (empty != null) {
            slivers.add(box(empty, order++));
          } else if (wide) {
            final int base = order;
            slivers.add(
              SliverCrossAxisGroup(
                key: const ValueKey<String>('stat-dashboard-wide-columns'),
                slivers: <Widget>[
                  SliverCrossAxisExpanded(
                    flex: 3,
                    sliver: SliverMainAxisGroup(
                      slivers: <Widget>[
                        for (int i = 0; i < trend.length; i++)
                          box(trend[i], base + i),
                      ],
                    ),
                  ),
                  SliverCrossAxisExpanded(
                    flex: 2,
                    sliver: SliverMainAxisGroup(
                      slivers: <Widget>[
                        for (int i = 0; i < details.length; i++)
                          box(details[i], base + i),
                        ...detailSlivers,
                      ],
                    ),
                  ),
                ],
              ),
            );
          } else {
            for (final Widget section in <Widget>[...trend, ...details]) {
              slivers.add(box(section, order++));
            }
            slivers.addAll(detailSlivers);
          }
          slivers.add(tail);
          return CustomScrollView(
            key: const ValueKey<String>('stat-dashboard-scroll'),
            slivers: slivers,
          );
        },
      ),
    );
  }
}

/// 卡外的区块小标题（「时段明细」「按书」…）：与 [StatSectionCard] 卡头同一
/// 字重，左右与卡片对齐；[subtitle] 写在标题后（如所选范围），[trailing] 放
/// 行尾控件，[below] 放标题下一行的控件（如排序 chip）。
class StatSectionHeader extends StatelessWidget {
  const StatSectionHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
    this.below,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? sub = subtitle;
    final Widget? extra = below;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            header: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: statSectionTitleStyle(context),
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...<Widget>[
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.metadata.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (trailing case final Widget tr) tr,
              ],
            ),
          ),
          if (extra != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            extra,
          ],
        ],
      ),
    );
  }
}

/// 关键指标（今日 / 本周时长、今日 / 本周字数、连续天数、近 7 日活跃天数）。
@immutable
class StatKpis {
  const StatKpis({
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
/// 连续天数与阅读页同一个 [computeReadingStreak]（喂的是本页日面的活跃日）。
/// 总览喂筛选后的跨域日面，三个域页喂各自域的日面——同一函数、同一口径。
StatKpis computeStatKpis(Iterable<StatFact> daily, StatWindow w) {
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
  return StatKpis(
    todayMs: todayMs,
    weekMs: weekMs,
    prevWeekMs: prevWeekMs,
    todayChars: todayChars,
    weekChars: weekChars,
    streak: computeReadingStreak(active, w.now),
    activeDaysLast7: activeDaysLast7,
  );
}

/// 纯函数：本周计入每周目标的字数——与阅读页周目标同口径（学习域日面在
/// [w] 本周内的字数和；日分子见 `studyGoalCharsForDay`，BUG-1993）。
int studyGoalCharsForWeek(Iterable<StatFact> daily, StatWindow w) {
  int total = 0;
  for (final StatFact f in daily) {
    if (w.inWeek(f.dateKey)) total += f.chars;
  }
  return total;
}

/// 四张标准指标卡（今日时长 / 本周时长（较上周）/ 今日字数（本周）/ 连续天数
/// （近 7 日活跃））。四个统计页的指标区都从这里出，卡序、图标、说明行一致。
List<Widget> buildStatKpiTiles(BuildContext context, StatKpis kpis) {
  final StatChartColors colors = statChartColorsOf(context);
  final String weekDelta = formatWeekOverWeekDelta(
    kpis.weekMs,
    kpis.prevWeekMs,
  );
  final Color? weekDeltaColor = kpis.prevWeekMs == 0
      ? null
      : (kpis.weekMs >= kpis.prevWeekMs ? colors.up : colors.down);
  return <Widget>[
    StatKpiTile(
      key: const ValueKey<String>('stat-kpi-today-time'),
      icon: FushiIcons.calendar,
      label: t.stat_overview_today_time,
      value: formatStatTime(kpis.todayMs),
    ),
    StatKpiTile(
      key: const ValueKey<String>('stat-kpi-week-time'),
      icon: FushiIcons.calendar,
      label: t.stat_overview_week_time,
      value: formatStatTime(kpis.weekMs),
      caption: t.stat_overview_vs_last_week(delta: weekDelta),
      captionColor: weekDeltaColor,
    ),
    StatKpiTile(
      key: const ValueKey<String>('stat-kpi-today-chars'),
      icon: FushiIcons.language,
      label: t.stat_overview_today_chars,
      value: formatStatChars(kpis.todayChars),
      caption: t.stat_overview_week_chars(
        value: formatStatChars(kpis.weekChars),
      ),
    ),
    StatKpiTile(
      key: const ValueKey<String>('stat-kpi-streak'),
      icon: FushiIcons.streak,
      label: t.stat_streak,
      value: t.stat_format_days(n: kpis.streak),
      caption: t.stat_overview_active_days(n: kpis.activeDaysLast7),
    ),
  ];
}

/// 关键指标区：可选的 [lead]（目标面板）+ 指标卡 [tiles]。
///
/// 宽屏（≥ [kStatHeroWideMinWidth]）：有 [lead] 时 lead : 2×2 卡 = 2 : 3 并排，
/// 没有时所有卡一排；窄屏：lead 在上、卡片 2 列。同一排的卡等高。
class StatHero extends StatelessWidget {
  const StatHero({required this.tiles, super.key, this.lead, this.padding});

  final Widget? lead;
  final List<Widget> tiles;

  /// 外边距；null = 页面标准（左右上 [FushiSpacingTokens.card]、下 0）。对话框
  /// 内嵌时传 [EdgeInsets.zero]。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap + tokens.spacing.gap / 2;
    Widget rowOf(List<Widget> cells) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < cells.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: cells[i]),
          ],
        ],
      ),
    );
    Widget gridOf(List<Widget> cells, int columns) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < cells.length; i += columns) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          rowOf(<Widget>[
            ...cells.sublist(i, (i + columns).clamp(0, cells.length)),
            // 末行不满时补空位，保持列宽一致。
            for (int k = cells.length; k < i + columns; k++)
              const SizedBox.shrink(),
          ]),
        ],
      ],
    );
    final Widget? lead = this.lead;
    return Padding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            tokens.spacing.card,
            tokens.spacing.card,
            tokens.spacing.card,
            0,
          ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= kStatHeroWideMinWidth;
          if (wide && lead == null) return rowOf(tiles);
          final Widget grid = gridOf(tiles, 2);
          if (lead == null) return grid;
          if (wide) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 2, child: lead),
                  SizedBox(width: gap),
                  Expanded(flex: 3, child: grid),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              lead,
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
class StatKpiTile extends StatelessWidget {
  const StatKpiTile({
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
                StatIconBadge(icon: icon, color: colors.series),
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
                  // M3E Display 大数字：Emphasized 字重 + 等宽数字（换筛选时
                  // 数值切换宽度不跳）。
                  style: context.fushiType.headlineMediumEmphasized.tabular
                      .copyWith(color: scheme.onSurface),
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

/// 指标卡左上角的色调图标徽章：M3E = primaryContainer 饱和色块 + 四瓣饼干形
/// （墨水屏描边无底）；Apple 保持强调色 14% 圆底。
class StatIconBadge extends StatelessWidget {
  const StatIconBadge({required this.icon, required this.color, super.key});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return FushiListLeadingIcon(
        icon,
        shape: FushiLeadingShape.cookie,
        tone: FushiCardTone.primary,
        size: 32,
        iconSize: 18,
      );
    }
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

/// 目标面板（指标区的 lead）：设了目标 = 环形进度（进场时弧从 0 长到当前值）+
/// 进度文案，另设了每周目标时下面多一条周进度条；都没设 = 引导文案。整卡可点进
/// 目标编辑（与页头旗标按钮同一个入口）。
///
/// 环优先画每日目标；只设了每周目标时环画每周。分子由调用方传入（学习域
/// `studyGoalCharsForDay` 口径，BUG-1993），面板不重算。
class StatGoalPanel extends StatelessWidget {
  const StatGoalPanel({
    required this.goalChars,
    required this.progressChars,
    required this.onTap,
    super.key,
    this.weeklyGoalChars = 0,
    this.weeklyProgressChars = 0,
  });

  /// 每日目标字数；≤ 0 = 未设。
  final int goalChars;

  /// 今日计入目标的字数。
  final int progressChars;

  /// 每周目标字数；≤ 0 = 未设。
  final int weeklyGoalChars;

  /// 本周计入目标的字数。
  final int weeklyProgressChars;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final StatChartColors colors = statChartColorsOf(context);
    final Widget body;
    if (goalChars <= 0 && weeklyGoalChars <= 0) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatIconBadge(icon: FushiIcons.flag, color: colors.series),
          SizedBox(width: tokens.spacing.card),
          Flexible(
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
      final bool daily = goalChars > 0;
      final int goal = daily ? goalChars : weeklyGoalChars;
      final int progress = daily ? progressChars : weeklyProgressChars;
      final String title = daily ? t.stat_goal_daily : t.stat_goal_weekly;
      final double fraction = (progress / goal).clamp(0.0, 1.0);
      final bool reached = progress >= goal;
      final Color ringColor = reached ? colors.reached : colors.series;
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatChartEntrance(
            replayKey: fraction,
            builder: (BuildContext context, double p) => StatRing(
              fraction: fraction * p,
              color: ringColor,
              trackColor: ringColor.withValues(alpha: 0.16),
              value: '${(fraction * 100 * p).round()}%',
              caption: title,
              size: 104,
              strokeWidth: 10,
            ),
          ),
          SizedBox(width: tokens.spacing.card),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: statSectionTitleStyle(context)),
                SizedBox(height: tokens.spacing.gap / 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    t.stat_goal_progress(read: progress, goal: goal),
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
                          value: formatStatChars(goal - progress),
                        ),
                  style: tokens.type.metadata.copyWith(
                    color: reached ? colors.reached : scheme.onSurfaceVariant,
                    fontWeight: reached ? FontWeight.w600 : null,
                  ),
                ),
                if (daily && weeklyGoalChars > 0) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  _StatWeeklyGoalBar(
                    read: weeklyProgressChars,
                    goal: weeklyGoalChars,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }
    return FushiCard(
      key: const ValueKey<String>('stat-goal-panel'),
      onTap: onTap,
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Center(child: body),
    );
  }
}

/// 目标面板里的每周目标进度条（标签 + 条 + 「已读 / 目标」）。
class _StatWeeklyGoalBar extends StatelessWidget {
  const _StatWeeklyGoalBar({required this.read, required this.goal});

  final int read;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final StatChartColors colors = statChartColorsOf(context);
    final bool reached = goalReached(read, goal);
    final Color barColor = reached ? colors.reached : colors.series;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${t.stat_goal_weekly} · ${t.stat_goal_progress(read: read, goal: goal)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata.copyWith(
              color: reached ? colors.reached : scheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          StatChartEntrance(
            replayKey: read,
            builder: (BuildContext context, double p) => ClipRRect(
              borderRadius: tokens.radii.chipRadius,
              child: FushiLinearProgressIndicator(
                value: (goalProgressFraction(read, goal) ?? 0) * p,
                minHeight: 6,
                backgroundColor: isGlassDesign(context)
                    ? null
                    : barColor.withValues(alpha: 0.16),
                color: barColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空数据态：当前页（或当前筛选）下一条记录都没有时，取代趋势与明细区块；
/// 指标区照常显示（全 0），版式与有数据时一致。
class StatDashboardEmpty extends StatelessWidget {
  const StatDashboardEmpty({required this.message, super.key});

  final String message;

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
        key: const ValueKey<String>('stat-dashboard-empty'),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.card,
          vertical: tokens.spacing.card * 2,
        ),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.statistics,
          message: message,
        ),
      ),
    );
  }
}

/// 统计详情 sheet / 对话框的头部（时段明细、全部会话、单作品会话）：与页面
/// 区块标题同一字重体系、大一档，副标题写区间汇总，[trailing] 放行尾动作。
class StatSheetHeader extends StatelessWidget {
  const StatSheetHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final String? sub = subtitle;
    return Semantics(
      header: true,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.titleLarge.copyWith(
                    fontWeight: FontWeight.w600,
                    color: statSectionTitleStyle(context).color,
                  ),
                ),
                if (sub != null && sub.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    sub,
                    style: tokens.type.metadata.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing case final Widget tr) tr,
        ],
      ),
    );
  }
}
