import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

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

    _bookData = bookMap.values.toList()
      ..sort((a, b) => b.chars.compareTo(a.chars));
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
        SliverToBoxAdapter(child: _buildHourlyChart()),
        SliverToBoxAdapter(child: _buildDailyChart()),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            child: Text(t.stat_by_book,
                style: Theme.of(context).textTheme.titleMedium),
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

  Widget _buildBookTile(_BookData book) {
    final maxChars =
        _bookData.isEmpty ? 1 : _bookData.first.chars.clamp(1, 1 << 50);
    final fraction = book.chars / maxChars;
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
}
