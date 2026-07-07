import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:hibiki/src/pages/implementations/stat_kpi_strip.dart';
import 'package:hibiki/src/pages/implementations/stat_ring.dart';
import 'package:hibiki/src/pages/implementations/stat_summary.dart';
import 'package:hibiki/src/pages/implementations/stat_trends.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 「按书」列表的排序键：字数 / 时长 / 阅读速度（cph）。
enum _BookSort { chars, time, speed }

/// 「今天」环形进度在用户未设目标时的回退目标（仅用于可视化，不写库）。
const int _kDailyCharGoalFallback = 5000;
const int _kDailyTimeGoalMinutes = 60;

/// 宽屏断点：>= 此宽度时「今天」与「速度摘要」并排，内容整体居中限宽。
const double _kWideBreakpoint = 720;
const double _kMaxContentWidth = 1040;

class ReadingStatisticsPage extends BasePage {
  const ReadingStatisticsPage({super.key});

  @override
  BasePageState<ReadingStatisticsPage> createState() =>
      _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends BasePageState<ReadingStatisticsPage> {
  bool _loading = true;
  String? _error;

  List<ReadingStatisticRow> _allStats = [];

  // 聚合数据
  int _todayChars = 0;
  int _todayMs = 0;
  int _weekChars = 0;
  int _weekMs = 0;
  int _monthChars = 0;
  int _monthMs = 0;
  int _allChars = 0;
  int _allMs = 0;

  // 每日数据（最近 30 天）
  List<StatDayData> _dailyData = [];

  // 今日每小时数据（0-23）
  List<int> _hourlyMs = List.filled(24, 0);

  // 制卡 / 收藏计数（来源 'book'），按今日/本周/本月/全部分桶。
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  // 查词计数（来源 'book'）按今日/本周/本月/全部分桶（TODO-1204）。
  StatActivityBuckets _lookup = StatActivityBuckets();

  // per-book 查词/制卡计数（按 title 聚合，对齐字数/时长 tile 的聚合键）。
  Map<String, ({int lookups, int mines})> _bookCounters =
      <String, ({int lookups, int mines})>{};

  // per-book 收藏计数（TODO-1252：按 title 聚合当前收藏活行，无书收藏 title='' 跳过，
  // 只进汇总面板）。收藏取消即删行 → 聚合活行天然回落。
  Map<String, int> _bookFavorites = <String, int>{};

  // 按书聚合
  List<_BookData> _bookData = [];

  // 总览：总书数 / 活跃天数 / 日期范围（min/max dateKey，可空表示无数据）。
  int _totalBooks = 0;
  int _activeDays = 0;
  int _streak = 0;
  String? _firstDateKey;
  String? _lastDateKey;

  // 速度摘要（从最近 30 天纯函数算出）。
  SpeedSummary? _speedSummary;

  // 范围与趋势折线图的聚合粒度（日 / 周 / 月）与指标（字数 / 时长 / 速度）。
  StatTrendGranularity _trendGranularity = StatTrendGranularity.daily;
  StatTrendMetric _trendMetric = StatTrendMetric.chars;

  // 「按书」列表的排序键。
  _BookSort _bookSort = _BookSort.chars;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAndLoad());
  }

  Future<void> _syncAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    try {
      final db = appModelNoUpdate.database;
      _allStats = await db.getAllReadingStatistics();
      _computeAggregates();
      final DateTime now = DateTime.now();
      final List<FavoriteWordRow> favs =
          await db.getFavoriteWordsBySource(kStatSourceBook);
      final List<MiningStatisticRow> mined =
          await db.getMiningStatisticsBySource(kStatSourceBook);
      _favorited = bucketActivityByDateKey(
        favs.map((FavoriteWordRow f) => (f.dateKey, 1)),
        now,
      );
      _mined = bucketActivityByDateKey(
        mined.map((MiningStatisticRow m) => (m.dateKey, m.count)),
        now,
      );
      // TODO-1204：查词/制卡 per-book 计数（新表）。汇总用 lookupCount 分桶，
      // per-book tile 按 title 聚合（无书查词 title='' 跳过，只进汇总）。
      final List<LookupMiningCounterRow> counters =
          await db.getLookupMiningCountersBySource(kStatSourceBook);
      _lookup = bucketActivityByDateKey(
        counters.map((LookupMiningCounterRow c) => (c.dateKey, c.lookupCount)),
        now,
      );
      _bookCounters = _aggregateCountersByTitle(counters);
      _bookFavorites = _aggregateFavoritesByTitle(favs);
      // 收藏语句按 source 分桶：非视频来源（书内 / 有声书 / 歌词）都归阅读统计。
      // 旧条目无 dateKey（null）→ 不参与按日分桶（whereType 过滤掉）。
      final List<FavoriteSentence> favSentences =
          await FavoriteSentenceRepository(db).getAll();
      _favoritedSentences = bucketActivityByDateKey(
        favSentences
            .where((FavoriteSentence s) =>
                s.source != kFavoriteSentenceSourceVideo && s.dateKey != null)
            .map((FavoriteSentence s) => (s.dateKey!, 1)),
        now,
      );
      await _loadHourlyData();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReadingStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    setState(() => _loading = false);
  }

  Future<void> _loadHourlyData() async {
    final db = appModelNoUpdate.database;
    final todayKey = _dateKey(DateTime.now());
    final rows = await db.getHourlyLogsForDate(todayKey);
    _hourlyMs = List.filled(24, 0);
    for (final row in rows) {
      if (row.hour >= 0 && row.hour < 24) {
        _hourlyMs[row.hour] = row.readingTimeMs;
      }
    }
  }

  /// TODO-1204：把查词/制卡计数行按 [LookupMiningCounterRow.title] 聚合成
  /// (查词数, 制卡数)，供 per-book tile 展示。无书查词（title 空）不入 tile，只进
  /// 汇总面板。聚合键与字数/时长 tile 的 title 一致。
  Map<String, ({int lookups, int mines})> _aggregateCountersByTitle(
      List<LookupMiningCounterRow> rows) {
    final Map<String, ({int lookups, int mines})> out =
        <String, ({int lookups, int mines})>{};
    for (final LookupMiningCounterRow r in rows) {
      if (r.title.isEmpty) continue;
      final ({int lookups, int mines}) prev =
          out[r.title] ?? (lookups: 0, mines: 0);
      out[r.title] = (
        lookups: prev.lookups + r.lookupCount,
        mines: prev.mines + r.mineCount,
      );
    }
    return out;
  }

  /// TODO-1252：把收藏活行按 [FavoriteWordRow.title] 聚合成每本书的收藏数，供 per-book
  /// tile 展示。无书收藏（title 空）不入 tile，只进汇总面板。聚合键与查词/制卡 tile 的
  /// title 一致。
  Map<String, int> _aggregateFavoritesByTitle(List<FavoriteWordRow> rows) {
    final Map<String, int> out = <String, int>{};
    for (final FavoriteWordRow r in rows) {
      if (r.title.isEmpty) continue;
      out[r.title] = (out[r.title] ?? 0) + 1;
    }
    return out;
  }

  void _computeAggregates() {
    final now = DateTime.now();
    final todayKey = _dateKey(now);
    final weekAgoKey = _dateKey(now.subtract(const Duration(days: 7)));
    final monthAgoKey = _dateKey(now.subtract(const Duration(days: 30)));

    _todayChars = 0;
    _todayMs = 0;
    _weekChars = 0;
    _weekMs = 0;
    _monthChars = 0;
    _monthMs = 0;
    _allChars = 0;
    _allMs = 0;

    final dailyMap = <String, StatDayData>{};
    final bookMap = <String, _BookData>{};

    for (final s in _allStats) {
      _allChars += s.charactersRead;
      _allMs += s.readingTimeMs;

      if (s.dateKey == todayKey) {
        _todayChars += s.charactersRead;
        _todayMs += s.readingTimeMs;
      }
      if (s.dateKey.compareTo(weekAgoKey) >= 0) {
        _weekChars += s.charactersRead;
        _weekMs += s.readingTimeMs;
      }
      if (s.dateKey.compareTo(monthAgoKey) >= 0) {
        _monthChars += s.charactersRead;
        _monthMs += s.readingTimeMs;
      }

      // 每日
      final day = dailyMap.putIfAbsent(
          s.dateKey, () => StatDayData(dateKey: s.dateKey));
      day.chars += s.charactersRead;
      day.ms += s.readingTimeMs;

      // 按书
      final book =
          bookMap.putIfAbsent(s.title, () => _BookData(title: s.title));
      book.chars += s.charactersRead;
      book.ms += s.readingTimeMs;
    }

    // 最近 30 天，按日期排序
    final thirtyDaysAgo = now.subtract(const Duration(days: 29));
    _dailyData = [];
    for (int i = 0; i < 30; i++) {
      final d = thirtyDaysAgo.add(Duration(days: i));
      final key = _dateKey(d);
      _dailyData.add(dailyMap[key] ?? StatDayData(dateKey: key));
    }

    // 总览：总书数 = distinct title；活跃天数 = distinct dateKey；
    // 日期范围 = min/max dateKey（dateKey 零填充可字典序比较）。
    _totalBooks = bookMap.length;
    final Set<String> activeDayKeys =
        _allStats.map((ReadingStatisticRow s) => s.dateKey).toSet();
    _activeDays = activeDayKeys.length;
    _streak = computeReadingStreak(activeDayKeys, now);
    if (activeDayKeys.isEmpty) {
      _firstDateKey = null;
      _lastDateKey = null;
    } else {
      final List<String> sortedKeys = activeDayKeys.toList()..sort();
      _firstDateKey = sortedKeys.first;
      _lastDateKey = sortedKeys.last;
    }

    _speedSummary = computeSpeedSummary(_dailyData);

    _bookData = bookMap.values.toList();
    _sortBookData();
  }

  /// 按当前排序键给 [_bookData] 重排（不重新查 DB）。
  void _sortBookData() {
    switch (_bookSort) {
      case _BookSort.chars:
        _bookData
            .sort((_BookData a, _BookData b) => b.chars.compareTo(a.chars));
      case _BookSort.time:
        _bookData.sort((_BookData a, _BookData b) => b.ms.compareTo(a.ms));
      case _BookSort.speed:
        _bookData.sort((_BookData a, _BookData b) => b.cph.compareTo(a.cph));
    }
  }

  /// 当前排序维度下该书的度量值（字数 / 时长ms / 速度cph）。
  /// 进度条填充用它，使填充维度始终与 [_bookSort] 一致（W1）。
  double _sortMetric(_BookData b) {
    switch (_bookSort) {
      case _BookSort.chars:
        return b.chars.toDouble();
      case _BookSort.time:
        return b.ms.toDouble();
      case _BookSort.speed:
        return b.cph;
    }
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _formatTime(int ms) {
    final totalMin = ms ~/ 60000;
    if (totalMin < 60) return t.stat_format_minutes(n: totalMin);
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return t.stat_format_hours_minutes(h: h, m: m);
  }

  static String _formatChars(int chars) {
    if (chars >= 10000) {
      return t.stat_format_chars_wan(n: (chars / 10000).toStringAsFixed(1));
    }
    return t.stat_format_chars(n: chars);
  }

  /// 阅读速度展示：四舍五入到整数字/小时，套 i18n 单位。
  static String _formatCph(double cph) =>
      t.stat_speed_cph(n: cph.round().toString());

  /// 日期范围展示：`首日 ~ 末日`；无数据回退占位符。
  String _formatDateRange() {
    final String? first = _firstDateKey;
    final String? last = _lastDateKey;
    if (first == null || last == null) return '-';
    if (first == last) return first;
    return '$first ~ $last';
  }

  /// 指标名（趋势图图例 / 表头共用）。
  static String _metricLabel(StatTrendMetric m) {
    switch (m) {
      case StatTrendMetric.chars:
        return t.stat_metric_chars;
      case StatTrendMetric.time:
        return t.stat_metric_time;
      case StatTrendMetric.speed:
        return t.stat_metric_speed;
    }
  }

  @override
  Widget build(BuildContext context) {
    return HibikiPageScaffold(
      title: t.reading_statistics,
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.refresh,
          tooltip: t.stat_refresh,
          enabled: !_loading,
          onTap: _syncAndLoad,
        ),
        HibikiIconButton(
          icon: Icons.delete_sweep_outlined,
          tooltip: t.stat_clear_all,
          enabled: !_loading,
          onTap: _confirmAndClearAll,
        ),
      ],
      body: _loading
          ? buildLoading()
          : _error != null
              ? buildError(error: _error)
              : _allStats.isEmpty
                  ? Center(
                      child: HibikiPlaceholderMessage(
                        icon: Icons.bar_chart_outlined,
                        message: t.stat_no_data,
                      ),
                    )
                  : _buildContent(),
    );
  }

  Widget _buildContent() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double card = tokens.spacing.card;
    final EdgeInsets hPad = EdgeInsets.symmetric(horizontal: card);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= _kWideBreakpoint;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kMaxContentWidth),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(card, card, card, card),
                    child: _buildKpiStrip(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding:
                        EdgeInsets.only(left: card, right: card, bottom: card),
                    child: _buildTrendPanel(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding:
                        EdgeInsets.only(left: card, right: card, bottom: card),
                    child: _buildMidSection(wide),
                  ),
                ),
                SliverToBoxAdapter(child: _buildSummaryCards()),
                SliverToBoxAdapter(child: _buildGoalPanel()),
                SliverToBoxAdapter(child: _buildHourlyChart()),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(card,
                        card + tokens.spacing.gap, card, tokens.spacing.gap),
                    child: _buildByBookHeader(),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => Padding(
                      padding: hPad,
                      child: _buildBookTile(_bookData[index]),
                    ),
                    childCount: _bookData.length,
                  ),
                ),
                SliverPadding(padding: EdgeInsets.only(bottom: card * 2)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 「今天」环 + 「速度摘要」：宽屏并排，窄屏堆叠。
  Widget _buildMidSection(bool wide) {
    final double gap = HibikiDesignTokens.of(context).spacing.card;
    final Widget today = _buildTodayPanel();
    final Widget summary = _buildSpeedSummaryPanel();
    if (wide) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: today),
            SizedBox(width: gap),
            Expanded(child: summary),
          ],
        ),
      );
    }
    return Column(
      children: <Widget>[
        today,
        SizedBox(height: gap),
        summary,
      ],
    );
  }

  /// 顶部 KPI 概览条：全部字数 / 全部时长 / 书数 / 活跃天数。
  /// TODO-1253：交给自适应的 [StatKpiStrip]——宽屏一排、窄屏换行成 2 列，
  /// 避免手机上四张卡挤到内宽 ~40px 把数值 ellipsis 截没（「看不到数字」）。
  Widget _buildKpiStrip() {
    return StatKpiStrip(
      items: <StatKpiItem>[
        StatKpiItem(
          icon: Icons.text_fields,
          value: formatStatCharsAxis(_allChars),
          label: t.stat_metric_chars,
        ),
        StatKpiItem(
          icon: Icons.schedule,
          value: _formatTime(_allMs),
          label: t.stat_metric_time,
        ),
        StatKpiItem(
          icon: Icons.menu_book_outlined,
          value: _totalBooks.toString(),
          label: t.stat_total_books,
        ),
        StatKpiItem(
          icon: Icons.calendar_today_outlined,
          value: _activeDays.toString(),
          label: t.stat_active_days,
        ),
      ],
    );
  }

  /// 卡片外壳：标题 + 可选 trailing + 内容。
  Widget _card({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (trailing != null) Flexible(child: trailing),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          child,
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    final tokens = HibikiDesignTokens.of(context);

    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                  child: _summaryStatPanel(
                      t.stat_today,
                      _todayChars,
                      _todayMs,
                      _lookup.today,
                      _mined.today,
                      _favorited.today,
                      _favoritedSentences.today)),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Expanded(
                  child: _summaryStatPanel(
                      t.stat_this_week,
                      _weekChars,
                      _weekMs,
                      _lookup.week,
                      _mined.week,
                      _favorited.week,
                      _favoritedSentences.week)),
            ],
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          Row(
            children: [
              Expanded(
                  child: _summaryStatPanel(
                      t.stat_this_month,
                      _monthChars,
                      _monthMs,
                      _lookup.month,
                      _mined.month,
                      _favorited.month,
                      _favoritedSentences.month)),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Expanded(
                  child: _summaryStatPanel(
                      t.stat_all_time,
                      _allChars,
                      _allMs,
                      _lookup.all,
                      _mined.all,
                      _favorited.all,
                      _favoritedSentences.all)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryStatPanel(String label, int chars, int ms, int lookup,
      int mined, int favorited, int favoritedSentences) {
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = HibikiDesignTokens.of(context);
    final TextStyle? subStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
    return HibikiCard(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
            SizedBox(height: tokens.spacing.gap),
            Text(_formatChars(chars),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    )),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(_formatTime(ms), style: subStyle),
            SizedBox(height: tokens.spacing.gap / 2),
            Text('${t.stat_lookup}: $lookup', style: subStyle),
            SizedBox(height: tokens.spacing.gap / 2),
            Text('${t.stat_mined}: $mined', style: subStyle),
            SizedBox(height: tokens.spacing.gap / 2),
            Text('${t.stat_favorited}: $favorited', style: subStyle),
            SizedBox(height: tokens.spacing.gap / 2),
            Text('${t.stat_favorited_sentence}: $favoritedSentences',
                style: subStyle),
          ],
        ),
      ),
    );
  }

  /// TODO-1046: daily/weekly reading goal card. Both goals 0 => no card at all
  /// (SizedBox.shrink), so an install that never set a goal sees zero visual
  /// change on the statistics page. Reuses the already-computed [_todayChars] /
  /// [_weekChars] aggregates (no extra DB query).
  Widget _buildGoalPanel() {
    final int dailyGoal = appModelNoUpdate.readingGoalDailyChars;
    final int weeklyGoal = appModelNoUpdate.readingGoalWeeklyChars;
    if (dailyGoal <= 0 && weeklyGoal <= 0) {
      return const SizedBox.shrink();
    }

    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final List<Widget> rows = <Widget>[];
    if (dailyGoal > 0) {
      rows.add(_buildGoalRow(t.stat_goal_daily, _todayChars, dailyGoal));
    }
    if (dailyGoal > 0 && weeklyGoal > 0) {
      rows.add(SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2));
    }
    if (weeklyGoal > 0) {
      rows.add(_buildGoalRow(t.stat_goal_weekly, _weekChars, weeklyGoal));
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: HibikiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.stat_goal_set,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                  ),
                ),
                HibikiIconButton(
                  icon: Icons.edit,
                  tooltip: t.stat_goal_set,
                  onTap: _editGoals,
                ),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            ...rows,
          ],
        ),
      ),
    );
  }

  /// One goal row: label + progress bar + "read / goal" text. When the goal is
  /// reached ([goalReached]) the bar switches to the tertiary color as a
  /// positive accent. A goal of 0 never reaches here (the card gates on it).
  Widget _buildGoalRow(String label, int read, int goal) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final double? fraction = goalProgressFraction(read, goal);
    final bool reached = goalReached(read, goal);
    final Color barColor = reached ? colorScheme.tertiary : colorScheme.primary;
    final TextStyle? subStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            if (reached)
              Text(t.stat_goal_reached,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.tertiary,
                        fontWeight: FontWeight.bold,
                      )),
          ],
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        Row(
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: tokens.radii.chipRadius,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 8,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  color: barColor,
                ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
            Text(
              t.stat_goal_progress(read: read, goal: goal),
              style: subStyle,
            ),
          ],
        ),
      ],
    );
  }

  /// Number-input dialog to set/clear the daily & weekly character goals.
  /// Writing 0 clears (hides) that goal. setState reruns the sliver build so the
  /// card appears/updates/disappears immediately.
  Future<void> _editGoals() async {
    final TextEditingController dailyController = TextEditingController(
      text: appModelNoUpdate.readingGoalDailyChars == 0
          ? ''
          : appModelNoUpdate.readingGoalDailyChars.toString(),
    );
    final TextEditingController weeklyController = TextEditingController(
      text: appModelNoUpdate.readingGoalWeeklyChars == 0
          ? ''
          : appModelNoUpdate.readingGoalWeeklyChars.toString(),
    );

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(dialogContext);
        return AlertDialog(
          title: Text(t.stat_goal_set),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: dailyController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.stat_goal_daily),
              ),
              SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
              TextField(
                controller: weeklyController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.stat_goal_weekly),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(t.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(t.dialog_save),
            ),
          ],
        );
      },
    );

    final String dailyText = dailyController.text.trim();
    final String weeklyText = weeklyController.text.trim();
    dailyController.dispose();
    weeklyController.dispose();

    if (saved != true) return;

    final int daily = int.tryParse(dailyText) ?? 0;
    final int weekly = int.tryParse(weeklyText) ?? 0;
    await appModelNoUpdate.setReadingGoalDailyChars(daily < 0 ? 0 : daily);
    await appModelNoUpdate.setReadingGoalWeeklyChars(weekly < 0 ? 0 : weekly);
    if (!mounted) return;
    setState(() {});
  }

  /// 「今天」环形进度卡：字数目标环（复用持久化每日目标，未设则回退默认仅作可视化）
  /// + 时长目标环 + 速度 / 制卡 / 收藏迷你块。
  Widget _buildTodayPanel() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final int dailyGoal = appModelNoUpdate.readingGoalDailyChars;
    final int charGoal = dailyGoal > 0 ? dailyGoal : _kDailyCharGoalFallback;
    final double charFrac = goalFraction(_todayChars, charGoal);
    final int todayMinutes = _todayMs ~/ 60000;
    final double timeFrac = goalFraction(todayMinutes, _kDailyTimeGoalMinutes);
    final double todayCph = computeCph(_todayChars, _todayMs);

    return _card(
      title: t.stat_today,
      trailing: Text(
        _dateKey(DateTime.now()),
        style: tokens.type.metadata.copyWith(color: scheme.onSurfaceVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceAround,
            spacing: tokens.spacing.card,
            runSpacing: tokens.spacing.card,
            children: <Widget>[
              StatRing(
                fraction: charFrac,
                color: scheme.primary,
                trackColor: scheme.surfaceContainerHighest,
                value: '${(charFrac * 100).round()}%',
                detail: '$_todayChars/$charGoal',
                caption: t.stat_goal,
              ),
              StatRing(
                fraction: timeFrac,
                color: scheme.tertiary,
                trackColor: scheme.surfaceContainerHighest,
                value: '${(timeFrac * 100).round()}%',
                detail: _formatTime(_todayMs),
                caption: t.stat_metric_time,
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          Row(
            children: <Widget>[
              Expanded(
                child: _miniStat(t.stat_metric_speed,
                    todayCph > 0 ? _formatCph(todayCph) : '-'),
              ),
              Expanded(
                child: _miniStat(t.stat_streak, t.stat_format_days(n: _streak)),
              ),
              Expanded(
                child: _miniStat(t.stat_favorited, _favorited.today.toString()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Container(
      margin: EdgeInsets.only(right: tokens.spacing.gap),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 「速度摘要」卡：加权均速 / 典型日 / 近 7 活跃日 / 较前 14 天 / 最快·最慢日。
  Widget _buildSpeedSummaryPanel() {
    final SpeedSummary? s = _speedSummary;
    return _card(
      title: t.stat_speed_summary,
      child: s == null
          ? const SizedBox.shrink()
          : Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _summaryTile(t.stat_weighted_avg_speed,
                          _formatCph(s.weightedAvgCph)),
                    ),
                    Expanded(
                      child: _summaryTile(
                          t.stat_typical_day,
                          s.typicalDayCph != null
                              ? _formatCph(s.typicalDayCph!)
                              : '-'),
                    ),
                  ],
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _summaryTile(t.stat_recent_active,
                          t.stat_format_days(n: s.recentActiveDays)),
                    ),
                    Expanded(child: _deltaTile(s.deltaPercent)),
                  ],
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                        child: _extremeTile(t.stat_fastest_day, s.fastestDay)),
                    Expanded(
                        child: _extremeTile(t.stat_slowest_day, s.slowestDay)),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _summaryTile(String label, String value, {Color? valueColor}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        right: tokens.spacing.gap,
        bottom: tokens.spacing.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: valueColor ?? scheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _deltaTile(double? delta) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (delta == null) {
      return _summaryTile(t.stat_vs_prev, '-');
    }
    final bool up = delta >= 0;
    final String sign = up ? '+' : '';
    final Color color = up ? scheme.primary : scheme.error;
    return _summaryTile(t.stat_vs_prev, '$sign${delta.toStringAsFixed(0)}%',
        valueColor: color);
  }

  Widget _extremeTile(String label, StatExtremeDay? day) {
    if (day == null) return _summaryTile(label, '-');
    final String date =
        day.dateKey.length >= 10 ? day.dateKey.substring(5) : day.dateKey;
    return _summaryTile(label, '${_formatCph(day.cph)} · $date');
  }

  /// 「范围与趋势」折线卡：指标（字数/时长/速度）+ 粒度（日/周/月）切换 +
  /// 原始线 + 移动平均虚线（速度指标额外标异常点）。
  Widget _buildTrendPanel() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final List<StatTrendPoint> points =
        aggregateTrend(_dailyData, _trendGranularity);
    final List<double> values = points
        .map((StatTrendPoint p) => trendMetricValue(p, _trendMetric))
        .toList();
    final int window = _trendGranularity == StatTrendGranularity.daily ? 7 : 3;
    final List<double> avgValues = movingAverage(values, window);
    final List<bool> anomalies = _trendMetric == StatTrendMetric.speed
        ? detectAnomalies(values)
        : List<bool>.filled(values.length, false);
    final List<String> xLabels =
        points.map((StatTrendPoint p) => p.label).toList();
    final int labelEvery =
        _trendGranularity == StatTrendGranularity.daily ? 5 : 1;
    final TextStyle labelStyle = tokens.type.metadata.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final StatTrendMetric metric = _trendMetric;

    return _card(
      title: t.stat_range_and_trend,
      trailing: Text(
        _formatDateRange(),
        textAlign: TextAlign.right,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.metadata.copyWith(color: scheme.onSurfaceVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: StatTrendMetric.values
                .map((StatTrendMetric m) => HibikiSelectableChip(
                      label: _metricLabel(m),
                      selected: _trendMetric == m,
                      onSelected: (_) => setState(() => _trendMetric = m),
                    ))
                .toList(),
          ),
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              _granChip(t.stat_trend_daily, StatTrendGranularity.daily),
              _granChip(t.stat_trend_weekly, StatTrendGranularity.weekly),
              _granChip(t.stat_trend_monthly, StatTrendGranularity.monthly),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          SizedBox(
            height: 200,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatLineChartPainter(
                series: <StatLineSeries>[
                  StatLineSeries(values: values, color: scheme.primary),
                  StatLineSeries(
                    values: avgValues,
                    color: scheme.tertiary,
                    strokeWidth: 1.5,
                    dashed: true,
                  ),
                ],
                xLabels: xLabels,
                anomalies: anomalies,
                anomalyColor: scheme.error,
                labelColor: scheme.onSurfaceVariant,
                labelStyle: labelStyle,
                labelFormatter: (double v) => trendMetricAxisLabel(v, metric),
                labelEvery: labelEvery,
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          _trendLegend(),
        ],
      ),
    );
  }

  Widget _granChip(String label, StatTrendGranularity g) {
    return HibikiSelectableChip(
      label: label,
      selected: _trendGranularity == g,
      onSelected: (_) => setState(() => _trendGranularity = g),
    );
  }

  Widget _trendLegend() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        );
    return Wrap(
      spacing: tokens.spacing.card,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        _legendItem(scheme.primary, _metricLabel(_trendMetric), style),
        _legendItem(scheme.tertiary, t.stat_speed_avg, style),
        if (_trendMetric == StatTrendMetric.speed)
          _legendItem(scheme.error, t.stat_speed_anomaly, style),
      ],
    );
  }

  Widget _legendItem(Color color, String label, TextStyle? style) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: tokens.radii.chipRadius,
          ),
        ),
        SizedBox(width: tokens.spacing.gap / 2),
        Text(label, style: style),
      ],
    );
  }

  Widget _buildHourlyChart() {
    final tokens = HibikiDesignTokens.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stat_today_hourly,
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          SizedBox(
            height: 140,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatHourlyChartPainter(
                hourlyMs: _hourlyMs,
                barColor: colorScheme.tertiary,
                barRadius: tokens.radii.chipCorner,
                labelColor: colorScheme.onSurfaceVariant,
                labelStyle: tokens.type.metadata.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
        ],
      ),
    );
  }

  Widget _buildByBookHeader() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.stat_bookshelf_compare,
            style: Theme.of(context).textTheme.titleMedium),
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            HibikiSelectableChip(
              label: t.stat_sort_by_chars,
              selected: _bookSort == _BookSort.chars,
              onSelected: (_) => _changeBookSort(_BookSort.chars),
            ),
            HibikiSelectableChip(
              label: t.stat_sort_by_time,
              selected: _bookSort == _BookSort.time,
              onSelected: (_) => _changeBookSort(_BookSort.time),
            ),
            HibikiSelectableChip(
              label: t.stat_sort_by_speed,
              selected: _bookSort == _BookSort.speed,
              onSelected: (_) => _changeBookSort(_BookSort.speed),
            ),
          ],
        ),
      ],
    );
  }

  void _changeBookSort(_BookSort sort) {
    if (_bookSort == sort) return;
    setState(() {
      _bookSort = sort;
      _sortBookData();
    });
  }

  /// 长按 / 右键某本书那一行 → 确认 → 删除该书的纯统计并写 book 墓碑防复活，再从
  /// DB 重新聚合刷新（TODO-1204 后续）。
  Future<void> _confirmAndDeleteBook(_BookData book) async {
    final bool confirmed = await confirmDeleteStatistics(context, book.title);
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.deleteReadingStatisticsForTitle(book.title);
    if (!mounted) return;
    await _loadFromDatabase();
  }

  /// TODO-1322：点顶栏「清空统计」→ 危险操作确认 → 清空**全部阅读统计**（阅读时长 /
  /// 字数 / 时段日志 / 查词 / 制卡计数；不动收藏 / 制卡历史 / 书籍），再从 DB 重新聚合刷新。
  Future<void> _confirmAndClearAll() async {
    final bool confirmed = await confirmClearAllStatistics(
      context,
      t.stat_clear_all_reading_message,
    );
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.clearAllReadingStatistics();
    if (!mounted) return;
    await _loadFromDatabase();
  }

  Widget _buildBookTile(_BookData book) {
    // TODO-1204：查词/制卡计数按 title 聚合（无记录则 0）。
    final ({int lookups, int mines}) counter =
        _bookCounters[book.title] ?? (lookups: 0, mines: 0);
    final int favorites = _bookFavorites[book.title] ?? 0;
    // 进度条填充维度 = 当前排序维度（W1）：first 是当前排序下第一名（最大值）。
    final double topMetric =
        _bookData.isEmpty ? 0 : _sortMetric(_bookData.first);
    final double fraction = bookProgressFraction(_sortMetric(book), topMetric);
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = HibikiDesignTokens.of(context);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // 移动端长按、桌面端右键（onSecondaryTap）都弹删除确认（书架同款交互）。
        onLongPress: () => _confirmAndDeleteBook(book),
        onSecondaryTap: () => _confirmAndDeleteBook(book),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: tokens.spacing.gap / 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: tokens.radii.chipRadius,
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 8,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
                  Text(
                    '${_formatChars(book.chars)} · ${_formatTime(book.ms)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                '${t.stat_lookup}: ${counter.lookups} · ${t.stat_mined}: ${counter.mines} · ${t.stat_favorited}: $favorites',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              SizedBox(height: tokens.spacing.gap / 2),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookData {
  _BookData({required this.title});
  final String title;
  int chars = 0;
  int ms = 0;

  /// 该书阅读速度（字/小时）。复用统一口径的 [computeCph]。
  double get cph => computeCph(chars, ms);
}
