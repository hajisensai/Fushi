import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_trends.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 「按书」列表的排序键：字数 / 时长 / 阅读速度（cph）。
enum _BookSort { chars, time, speed }

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

  // 按书聚合
  List<_BookData> _bookData = [];

  // 总览：总书数 / 活跃天数 / 日期范围（min/max dateKey，可空表示无数据）。
  int _totalBooks = 0;
  int _activeDays = 0;
  String? _firstDateKey;
  String? _lastDateKey;

  // 速度趋势折线图的聚合粒度（日 / 周 / 月）。
  StatTrendGranularity _trendGranularity = StatTrendGranularity.daily;

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
    if (activeDayKeys.isEmpty) {
      _firstDateKey = null;
      _lastDateKey = null;
    } else {
      final List<String> sortedKeys = activeDayKeys.toList()..sort();
      _firstDateKey = sortedKeys.first;
      _lastDateKey = sortedKeys.last;
    }

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
    final tokens = HibikiDesignTokens.of(context);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(child: _buildGoalCard()),
        SliverToBoxAdapter(child: _buildOverviewPanel()),
        SliverToBoxAdapter(child: _buildHourlyChart()),
        SliverToBoxAdapter(child: _buildDailyChart()),
        SliverToBoxAdapter(child: _buildSpeedTrendChart()),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            child: _buildByBookHeader(),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildBookTile(_bookData[index]),
            childCount: _bookData.length,
          ),
        ),
        SliverPadding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card * 2)),
      ],
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
                      _mined.today,
                      _favorited.today,
                      _favoritedSentences.today)),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Expanded(
                  child: _summaryStatPanel(
                      t.stat_this_week,
                      _weekChars,
                      _weekMs,
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
                      _mined.month,
                      _favorited.month,
                      _favoritedSentences.month)),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Expanded(
                  child: _summaryStatPanel(t.stat_all_time, _allChars, _allMs,
                      _mined.all, _favorited.all, _favoritedSentences.all)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryStatPanel(String label, int chars, int ms, int mined,
      int favorited, int favoritedSentences) {
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

  Widget _buildDailyChart() {
    final tokens = HibikiDesignTokens.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stat_last_30_days,
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          SizedBox(
            height: 160,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatBarChartPainter(
                data: _dailyData,
                barColor: colorScheme.primary,
                barRadius: tokens.radii.chipCorner,
                labelColor: colorScheme.onSurfaceVariant,
                labelStyle: tokens.type.metadata.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// overview card: total books / active days / avg speed (cph) / date range.
  Widget _buildOverviewPanel() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double avgCph = computeCph(_allChars, _allMs);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: HibikiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.stat_overview,
                style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: tokens.spacing.gap),
            Row(
              children: <Widget>[
                Expanded(
                    child: _overviewMetric(
                        t.stat_total_books, _totalBooks.toString())),
                Expanded(
                    child: _overviewMetric(
                        t.stat_active_days, _activeDays.toString())),
                Expanded(
                    child: _overviewMetric(
                        t.stat_reading_speed, _formatCph(avgCph))),
              ],
            ),
            SizedBox(height: tokens.spacing.gap),
            _overviewMetric(t.stat_date_range, _formatDateRange()),
          ],
        ),
      ),
    );
  }

  Widget _overviewMetric(String label, String value) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                )),
        SizedBox(height: tokens.spacing.gap / 2),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                )),
      ],
    );
  }

  Widget _buildSpeedTrendChart() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    final List<StatTrendPoint> points =
        aggregateTrend(_dailyData, _trendGranularity);
    final List<double> cphValues =
        points.map((StatTrendPoint p) => p.cph).toList();
    final int window = _trendGranularity == StatTrendGranularity.daily ? 7 : 3;
    final List<double> avgValues = movingAverage(cphValues, window);
    final List<bool> anomalies = detectAnomalies(cphValues);
    final List<String> xLabels =
        points.map((StatTrendPoint p) => p.label).toList();
    final int labelEvery =
        _trendGranularity == StatTrendGranularity.daily ? 5 : 1;

    final TextStyle labelStyle = tokens.type.metadata.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
          Text(t.stat_speed_trend,
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.spacing.gap),
          _trendGranularityChips(),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          SizedBox(
            height: 180,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatLineChartPainter(
                series: <StatLineSeries>[
                  StatLineSeries(
                    values: cphValues,
                    color: colorScheme.primary,
                  ),
                  StatLineSeries(
                    values: avgValues,
                    color: colorScheme.tertiary,
                    strokeWidth: 1.5,
                    dashed: true,
                  ),
                ],
                xLabels: xLabels,
                anomalies: anomalies,
                anomalyColor: colorScheme.error,
                labelColor: colorScheme.onSurfaceVariant,
                labelStyle: labelStyle,
                labelFormatter: _cphAxisLabel,
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

  String _cphAxisLabel(double v) => v.round().toString();

  Widget _trendGranularityChips() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap,
      children: <Widget>[
        HibikiSelectableChip(
          label: t.stat_trend_daily,
          selected: _trendGranularity == StatTrendGranularity.daily,
          onSelected: (_) =>
              setState(() => _trendGranularity = StatTrendGranularity.daily),
        ),
        HibikiSelectableChip(
          label: t.stat_trend_weekly,
          selected: _trendGranularity == StatTrendGranularity.weekly,
          onSelected: (_) =>
              setState(() => _trendGranularity = StatTrendGranularity.weekly),
        ),
        HibikiSelectableChip(
          label: t.stat_trend_monthly,
          selected: _trendGranularity == StatTrendGranularity.monthly,
          onSelected: (_) =>
              setState(() => _trendGranularity = StatTrendGranularity.monthly),
        ),
      ],
    );
  }

  Widget _trendLegend() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
    return Wrap(
      spacing: tokens.spacing.card,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        _legendItem(colorScheme.primary, t.stat_reading_speed, style),
        _legendItem(colorScheme.tertiary, t.stat_speed_avg, style),
        _legendItem(colorScheme.error, t.stat_speed_anomaly, style),
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

  Widget _buildByBookHeader() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.stat_by_book, style: Theme.of(context).textTheme.titleMedium),
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

  /// TODO-1046: daily/weekly reading goal card. Both goals 0 => no card at all
  /// (SizedBox.shrink), so an install that never set a goal sees zero visual
  /// change on the statistics page. Reuses the already-computed [_todayChars] /
  /// [_weekChars] aggregates (no extra DB query).
  Widget _buildGoalCard() {
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
              const SizedBox(height: 12),
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

  Widget _buildBookTile(_BookData book) {
    // 进度条填充维度 = 当前排序维度（W1）：first 是当前排序下第一名（最大值）。
    final double topMetric =
        _bookData.isEmpty ? 0 : _sortMetric(_bookData.first);
    final double fraction = bookProgressFraction(_sortMetric(book), topMetric);
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = HibikiDesignTokens.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
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
        ],
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
