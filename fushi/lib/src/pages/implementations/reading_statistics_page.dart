import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_hourly_breakdown.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_kpi_strip.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_ring.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/stat_source_totals.dart';
import 'package:fushi/src/pages/implementations/stat_summary.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「按书」列表的排序键：字数 / 时长 / 阅读速度（cph）。
enum _BookSort { chars, time, speed }

/// 「今天」环形进度在用户未设目标时的回退目标（仅用于可视化，不写库）。
const int _kDailyCharGoalFallback = 5000;
const int _kDailyTimeGoalMinutes = 60;

/// 宽屏断点：>= 此宽度时「今天」与「速度摘要」并排，内容整体居中限宽。
const double _kWideBreakpoint = 720;
const double _kMaxContentWidth = 1040;

class ReadingStatisticsPage extends BasePage {
  const ReadingStatisticsPage({super.key, this.embedded = false});

  /// true = 作为统计中心的一个 tab 嵌入（不套 FushiPageScaffold，动作行内联）。
  final bool embedded;

  @override
  BasePageState<ReadingStatisticsPage> createState() =>
      _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends BasePageState<ReadingStatisticsPage> {
  bool _loading = true;
  String? _error;

  /// 阅读域（普通书 + 漫画）的日面事实：v92 起只从统一事实面 [loadStatFacts] 取
  /// （legacy `reading_statistics` 日行 + `study_segments` 段），不再直接读表。
  List<StatFact> _bookFacts = <StatFact>[];

  /// 阅读域逐日合计：普通书与漫画同属阅读统计，视频和游戏由各自统计页负责。
  Map<StatBreakdownSource, Map<String, StatSourceTotals>> _sourceDaily =
      <StatBreakdownSource, Map<String, StatSourceTotals>>{};

  /// 「各来源」卡展示的窗口合计（今日 / 本周 / 本月 / 全部随 [_breakdownWindow]）。
  Map<StatBreakdownSource, StatSourceTotals> _breakdownTotals =
      <StatBreakdownSource, StatSourceTotals>{};

  /// 「各来源」卡的窗口：0=今日 1=本周 2=本月 3=全部（默认全部）。
  int _breakdownWindow = 3;

  /// 合集归属映射（书架同源）：按书 tile 显示所属合集名用。
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'epub|<uid>' → 折叠归属的主 collectionId
  ///   （v83：成员表 epub entryKey = `epub_books.uid`）。
  /// - [_bookKeyByTitle]：legacy 无身份行（mediaKey ''）只有 title，经 epub_books
  ///   反查 bookKey 的回退表；带身份的事实直接用 [_BookData.bookKey]。
  /// - [_epubUidByBookKey]：bookKey → uid 换算表（查归属映射前转一跳）。
  Map<int, String> _collectionNamesById = <int, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<String, String> _bookKeyByTitle = <String, String>{};
  Map<String, String> _epubUidByBookKey = <String, String>{};

  /// 库里同名 ≥2 本的 title（BUG-2216：按书分组的吸收否决，legacy 无身份行不许
  /// 吸进任何一本）。
  Set<String> _ambiguousBookTitles = <String>{};

  /// **本轮加载时**的统计窗口：聚合、「各来源」谓词、时段卡谓词全部用这一个
  /// （BUG-2219：此前聚合用加载时刻、卡片谓词点击时现算，跨午夜后「今日」卡的数
  /// 与明细对不上）。跨午夜由 [_midnightReload] 触发整页重聚合。
  StatWindow _window = StatWindow(DateTime.now());
  Timer? _midnightReload;

  // 聚合数据
  int _todayChars = 0;
  int _todayMs = 0;
  int _weekChars = 0;
  int _weekMs = 0;
  // 学习域目标分子（今日 / 本周，书 + 视频字幕 + 游戏 hook 文本）：目标卡与
  // 「今天」环形卡的目标环用它，与首页「今日目标」同函数同口径
  // （[studyGoalCharsForDay]，BUG-1993）。本页其余 KPI / 趋势 / CPH 仍是
  // 阅读域（[_todayChars] 等），两组数并存不混用。
  int _todayStudyChars = 0;
  int _weekStudyChars = 0;
  // 完整日面（全部来源），学习域目标分子的数据源。
  List<StatFact> _dailyFacts = <StatFact>[];
  // 上周字数（第 8–14 天窗口）：仅用于顶部 KPI 的本周字数环比，[8,14) 与本周 [0,7) 不重叠。
  int _prevWeekChars = 0;
  int _monthChars = 0;
  int _monthMs = 0;
  int _allChars = 0;
  int _allMs = 0;

  // 每日数据（最近 30 天）
  List<StatDayData> _dailyData = [];

  // 今日每小时数据（0-23），按写入面（format）分带。v67 前的行没有身份，落在
  // StatHourlyFormatBand.unattributed，图上单独成带、不归入任何阅读面。
  StatHourlyBreakdown _hourly = StatHourlyBreakdown();

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

  // 总览：日期范围（min/max dateKey，可空表示无数据）。
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

  @override
  void dispose() {
    _midnightReload?.cancel();
    super.dispose();
  }

  /// 到下一个本地午夜整页重聚合（每次加载重新排一次；页面已卸载则不动）。
  void _armMidnightReload(DateTime now) {
    _midnightReload?.cancel();
    _midnightReload = Timer(StatWindow.untilNextStatDayBoundary(now), () {
      if (mounted) unawaited(_loadFromDatabase());
    });
  }

  /// 统计中心把三页塞进 TabBarView（无 keepAlive，离屏即 unmount），
  /// 「点开 tab → DB 还在查 → 切走」是一秒可复现的常规操作：首帧 postFrameCallback
  /// 与多次 await 之后的两处 setState 都必须过 mounted 门，否则 debug 断言
  /// `setState() called after dispose()`、release 打在已置空的 _element 上。
  Future<void> _syncAndLoad() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    final DateTime now = DateTime.now();
    _window = StatWindow(now);
    _armMidnightReload(now);
    try {
      final db = appModelNoUpdate.database;
      // v92：统一事实面是**唯一**读取入口——legacy 日行的身份 / format（漫画从
      // 「阅读」里拆出来单列，页数是漫画独有的第三个量纲）已在里面按 title 反查
      // 库表补好，段自带身份。本页只取阅读域（书 + 漫画）的日面；统计页不需要
      // 活动行，activityLimit 传 0。
      final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
      _bookFacts = facts.dailyBooks.toList();
      _dailyFacts = facts.daily;
      _sourceDaily = aggregateStatSourceDaily(_bookFacts);
      // 加载事实时顺带取的书表：下面的 title→bookKey（合集归属 / legacy 行回退）
      // 与 bookKey→uid 换算复用同一批行，不再单独查。
      final List<EpubBookRow> epubRows = facts.epubRows;
      _ambiguousBookTitles = ambiguousBookTitles(epubRows);
      _computeAggregates();
      final List<FavoriteWordRow> favs = await db.getFavoriteWordsBySource(
        kStatSourceBook,
      );
      final List<MiningStatisticRow> mined = await db
          .getMiningStatisticsBySource(kStatSourceBook);
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
      final List<LookupMiningCounterRow> counters = await db
          .getLookupMiningCountersBySource(kStatSourceBook);
      _lookup = bucketActivityByDateKey(
        counters.map((LookupMiningCounterRow c) => (c.dateKey, c.lookupCount)),
        now,
      );
      _bookCounters = aggregateStatCountersByTitle(counters);
      _bookFavorites = aggregateStatFavoritesByTitle(favs);
      // 合集归属（书架同源）：title→bookKey→'epub|bookKey'→合集名，喂 per-book tile。
      _collectionNamesById = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
      };
      _primaryCollectionByEntry = await db.getPrimaryCollectionIdByEntry();
      // BUG-2216：同名 ≥2 本的 title 不进反查表（贴给任意一本都是错贴）。
      _bookKeyByTitle = uniqueBookKeyByTitle(epubRows);
      // v83：成员表 epub entryKey = uid，同批行顺带建换算表（空 uid 异常行不进
      // 表，查归属时按 bookKey 原样回退）。
      _epubUidByBookKey = <String, String>{
        for (final EpubBookRow r in epubRows)
          if (r.uid.isNotEmpty) r.bookKey: r.uid,
      };
      // 收藏语句按 source 分桶：非视频来源（书内 / 有声书 / 歌词）都归阅读统计。
      // BUG-893：写入端此前不带 dateKey，旧的 `dateKey != null` 过滤把所有书内收藏
      // 滤光 → 统计恒为 0。改用 `dateKey ?? statDateKey(createdAt)` 回退——createdAt
      // 恒非空，已存的无 dateKey 收藏也按创建日归桶（与写入端补 dateKey 双向修复）。
      final List<FavoriteSentence> favSentences =
          await FavoriteSentenceRepository(db).getAll();
      _favoritedSentences = bucketActivityByDateKey(
        favSentences
            .where(
              (FavoriteSentence s) => s.source != kFavoriteSentenceSourceVideo,
            )
            .map(
              (FavoriteSentence s) =>
                  (s.dateKey ?? statDateKey(s.createdAt), 1),
            ),
        now,
      );
      _loadHourlyData(facts);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReadingStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 今日时段图：从事实面的**小时面**取今日阅读域行（legacy `reading_hourly_logs`
  /// 行 + 今日的段），不再单独查表。同一 (band, hour) 多行按带累加：图表分色堆叠，
  /// `''`（v67 前写入 / 旧端同步差额）如实归 unattributed 带。
  void _loadHourlyData(StatFacts facts) {
    final String todayKey = _window.todayKey;
    final StatHourlyBreakdown breakdown = StatHourlyBreakdown();
    for (final StatFact f in facts.hourly) {
      if (!f.isBook || f.dateKey != todayKey) continue;
      breakdown.addMs(
        band: StatHourlyFormatBand.ofDbValue(f.format),
        hour: f.hour,
        ms: f.ms,
      );
    }
    _hourly = breakdown;
  }

  void _computeAggregates() {
    // 窗口阈值只从 StatWindow 取（近 7 天恰 7 天、上周 [now-13d, now-6d) 恰 7 天
    // 且与本周不重叠、近 30 天恰 30 天），本页不再自己算日期；且只用本轮加载时的
    // 那一个窗口（BUG-2219）。
    final StatWindow w = _window;
    final DateTime now = w.now;

    _todayChars = 0;
    _todayMs = 0;
    _weekChars = 0;
    _weekMs = 0;
    _todayStudyChars = 0;
    _weekStudyChars = 0;
    _prevWeekChars = 0;
    _monthChars = 0;
    _monthMs = 0;
    _allChars = 0;
    _allMs = 0;

    final dailyMap = <String, StatDayData>{};
    final bookMap = <String, _BookData>{};

    // 阅读统计只合并阅读域的普通书与漫画。视频 / 游戏有各自统计页，不进入本页
    // KPI、趋势或活跃天数；唯一例外是目标进度——目标是学习域概念（BUG-1993），
    // 分子在下方单独按完整日面求和。
    for (final StatBreakdownSource source in const <StatBreakdownSource>[
      StatBreakdownSource.book,
      StatBreakdownSource.manga,
    ]) {
      final Map<String, StatSourceTotals> byDay =
          _sourceDaily[source] ?? const <String, StatSourceTotals>{};
      byDay.forEach((String dateKey, StatSourceTotals totals) {
        _allChars += totals.chars;
        _allMs += totals.timeMs;
        if (w.isToday(dateKey)) _todayMs += totals.timeMs;
        if (w.inWeek(dateKey)) {
          _weekChars += totals.chars;
          _weekMs += totals.timeMs;
        } else if (w.inPrevWeek(dateKey)) {
          _prevWeekChars += totals.chars;
        }
        if (w.inMonth(dateKey)) {
          _monthChars += totals.chars;
          _monthMs += totals.timeMs;
        }
        final StatDayData day = dailyMap.putIfAbsent(
          dateKey,
          () => StatDayData(dateKey: dateKey),
        );
        day.chars += totals.chars;
        day.ms += totals.timeMs;
      });
    }

    // 今日阅读字数（阅读域切片，喂概览「今日」与 CPH）；目标分子另算学习域
    // （完整日面，与首页「今日目标」同源同函数，BUG-1993）。
    _todayChars = studyGoalCharsForDay(_bookFacts, w.todayKey);
    _todayStudyChars = studyGoalCharsForDay(_dailyFacts, w.todayKey);
    for (final StatFact f in _dailyFacts) {
      if (w.inWeek(f.dateKey)) _weekStudyChars += f.chars;
    }

    // 按书：与视频域同一套身份分组（BUG-2216，[groupStatFactsByIdentity]）——有
    // bookKey 按身份；legacy 无身份行（书已删 / 同名歧义反查失败）unique-title 吸收
    // 进唯一身份组，同一本书的 legacy 日行与 v92 段合成一个 tile；歧义独立成无身份
    // tile。title 取组首见快照作展示 / 计数键。
    for (final StatIdentityGroup<StatFact> g in groupStatFactsByIdentity(
      _bookFacts,
      ambiguousTitles: _ambiguousBookTitles,
    )) {
      final _BookData book = bookMap.putIfAbsent(
        '${g.identity ?? ''}|${g.title}',
        () => _BookData(title: g.title, bookKey: g.identity),
      );
      for (final StatFact f in g.rows) {
        book.chars += f.chars;
        book.ms += f.ms;
      }
    }

    // 最近 30 天（含今日），升序补齐空日期。
    _dailyData = <StatDayData>[
      for (final String key in w.lastDayKeys(30))
        dailyMap[key] ?? StatDayData(dateKey: key),
    ];

    // 总览活跃天数只取阅读域日期；dateKey 零填充，可直接字典序比较。
    final Set<String> activeDayKeys = <String>{};
    for (final StatBreakdownSource source in const <StatBreakdownSource>[
      StatBreakdownSource.book,
      StatBreakdownSource.manga,
    ]) {
      for (final MapEntry<String, StatSourceTotals> entry
          in (_sourceDaily[source] ?? const <String, StatSourceTotals>{})
              .entries) {
        if (!entry.value.isEmpty) activeDayKeys.add(entry.key);
      }
    }
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
    _recomputeBreakdown();
  }

  /// 「各来源」卡当前窗口的日期谓词（0=今日 1=近 7 天 2=近 30 天 3=全部）。
  /// 阈值只从 [StatWindow] 取，与顶部 KPI 同一套窗口。
  bool Function(String dateKey) _breakdownPredicate() {
    final StatWindow w = _window;
    switch (_breakdownWindow) {
      case 0:
        return w.isToday;
      case 1:
        return w.inWeek;
      case 2:
        return w.inMonth;
      default:
        return (String dateKey) => true;
    }
  }

  /// 按当前窗口重算阅读域来源合计（普通书 + 漫画，纯内存，不重查 DB）。
  void _recomputeBreakdown() {
    final bool Function(String) inWindow = _breakdownPredicate();
    _breakdownTotals = <StatBreakdownSource, StatSourceTotals>{
      for (final StatBreakdownSource source in const <StatBreakdownSource>[
        StatBreakdownSource.book,
        StatBreakdownSource.manga,
      ])
        source: sumStatSourceTotals(
          _sourceDaily[source] ?? const <String, StatSourceTotals>{},
          inWindow,
        ),
    };
  }

  /// 按当前排序键给 [_bookData] 重排（不重新查 DB）。
  void _sortBookData() {
    switch (_bookSort) {
      case _BookSort.chars:
        _bookData.sort(
          (_BookData a, _BookData b) => b.chars.compareTo(a.chars),
        );
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
    final List<Widget> actions = <Widget>[
      // BUG-970：目标设置入口恒驻顶栏——目标卡在两目标皆 0 时整块隐藏
      // (_buildGoalPanel -> SizedBox.shrink)，卡内 edit 图标随之消失，
      // 否则从未设过目标的用户没有任何 UI 能首次设置目标。
      FushiIconButton(
        icon: Icons.flag_outlined,
        tooltip: t.stat_goal_set,
        enabled: !_loading,
        onTap: _editGoals,
      ),
      FushiIconButton(
        icon: Icons.refresh,
        tooltip: t.stat_refresh,
        enabled: !_loading,
        onTap: _syncAndLoad,
      ),
      FushiIconButton(
        icon: Icons.delete_sweep_outlined,
        tooltip: t.stat_clear_all,
        enabled: !_loading,
        onTap: _confirmAndClearAll,
      ),
    ];
    final Widget body = buildStatPageBody(
      loading: _loading,
      error: _error,
      isEmpty: _bookFacts.isEmpty,
      loadingBuilder: () =>
          buildLoading(size: 25, color: theme.colorScheme.primary),
      errorBuilder: (String error) => buildError(error: error),
      emptyMessage: t.stat_no_data,
      contentBuilder: _buildContent,
    );
    if (widget.embedded) return buildEmbeddedStatTab(context, actions, body);
    return FushiPageScaffold(
      title: t.reading_statistics,
      actions: actions,
      body: body,
    );
  }

  Widget _buildContent() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
                    padding: EdgeInsets.only(
                      left: card,
                      right: card,
                      bottom: card,
                    ),
                    child: _buildTrendPanel(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: card,
                      right: card,
                      bottom: card,
                    ),
                    child: _buildMidSection(wide),
                  ),
                ),
                SliverToBoxAdapter(child: _buildSummaryCards()),
                SliverToBoxAdapter(child: _buildSourceBreakdown()),
                SliverToBoxAdapter(child: _buildGoalPanel()),
                SliverToBoxAdapter(
                  child: buildStatHourlyFormatChartSection(context, _hourly),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      card,
                      card + tokens.spacing.gap,
                      card,
                      tokens.spacing.gap,
                    ),
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
    final double gap = FushiDesignTokens.of(context).spacing.card;
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

  /// 顶部 KPI 概览条：连续天数 / 今日 / 本周(带环比) / 日均。
  ///
  /// 旧版 4 张卡是「全部字数 / 全部时长 / 书数 / 活跃天数」纯累计值——只增不减、不驱动
  /// 任何行动。换成近期动量指标：streak 促成「明天还想读」；今日 / 日均对应当下强度；
  /// 本周带上周环比，一眼看出在涨还是在掉。累计与书数仍在下方「按书统计」与趋势图可查，
  /// 无需在顶部重复挂一遍。
  /// TODO-1253：交给自适应的 [StatKpiStrip]——宽屏一排、窄屏换行成 2 列，数值 FittedBox
  /// 缩放不截断。
  Widget _buildKpiStrip() {
    // BUG-892 后续：日均字数用与「30 天字符图」同一窗口的活跃日均值（[_dailyData] 即
    // 字符图数据），不再用终身均值——后者被历史低产日拉低、与同屏近期指标对不上。
    final int dailyAvgChars = dailyAverageChars(_dailyData);
    final double? weekPct = computeWeekOverWeekPercent(
      _weekChars,
      _prevWeekChars,
    );
    // BUG-2224：环比封顶（≥ 999% 显示 `↑>999%`，无基线显示 `—`）。
    final String weekDelta = formatWeekOverWeekDelta(
      _weekChars,
      _prevWeekChars,
    );
    return StatKpiStrip(
      items: <StatKpiItem>[
        StatKpiItem(
          icon: Icons.local_fire_department_outlined,
          value: t.stat_format_days(n: _streak),
          label: t.stat_streak,
        ),
        StatKpiItem(
          icon: Icons.today_outlined,
          value: _formatChars(_todayChars),
          label: t.stat_today,
        ),
        StatKpiItem(
          icon: Icons.trending_up,
          value: _formatChars(_weekChars),
          label: t.stat_this_week,
          delta: weekDelta,
          deltaUp: weekPct == null ? true : weekPct >= 0,
        ),
        StatKpiItem(
          icon: Icons.show_chart,
          value: _formatChars(dailyAvgChars),
          label: t.stat_daily_average,
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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

  /// 阅读域「各来源」卡：普通书与漫画各自的字数 + 时长，漫画额外显示页数。
  Widget _buildSourceBreakdown() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> rows = <Widget>[];
    for (final StatBreakdownSource source in const <StatBreakdownSource>[
      StatBreakdownSource.book,
      StatBreakdownSource.manga,
    ]) {
      final StatSourceTotals totals =
          _breakdownTotals[source] ?? StatSourceTotals();
      if (totals.isEmpty) continue;
      rows.add(_breakdownRow(source, totals));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(
        left: tokens.spacing.card,
        right: tokens.spacing.card,
        bottom: tokens.spacing.card,
      ),
      child: _card(
        title: t.stat_source_breakdown,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                _breakdownWindowChip(t.stat_today, 0),
                _breakdownWindowChip(t.stat_this_week, 1),
                _breakdownWindowChip(t.stat_this_month, 2),
                _breakdownWindowChip(t.stat_all_time, 3),
              ],
            ),
            SizedBox(height: tokens.spacing.card),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _breakdownWindowChip(String label, int window) => FushiSelectableChip(
    label: label,
    selected: _breakdownWindow == window,
    onSelected: (_) => setState(() {
      _breakdownWindow = window;
      _recomputeBreakdown();
    }),
  );

  /// 单个来源一行：图标 + 名称 + 「字数 · 时长（· 页数）」。
  Widget _breakdownRow(StatBreakdownSource source, StatSourceTotals totals) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label) = switch (source) {
      StatBreakdownSource.book => (Icons.menu_book, t.home_filter_read),
      StatBreakdownSource.manga => (Icons.photo_library, t.manga_library),
      StatBreakdownSource.video => (Icons.movie, t.home_filter_watch),
      StatBreakdownSource.game => (Icons.videogame_asset, t.home_filter_game),
    };
    final List<String> metrics = <String>[
      _formatChars(totals.chars),
      formatStatTime(totals.timeMs),
      // 页数只有漫画有；0 页不显示（未翻页的会话只贡献时长）。
      if (totals.pages > 0) t.stat_format_pages(n: totals.pages),
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Flexible(
            child: Text(
              metrics.join(' · '),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.metadata.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    // 时段谓词与聚合同一个窗口（BUG-2219）：跨午夜后由 [_midnightReload] 整页重聚合，
    // 卡上的数和点开的明细永远出自同一窗口。
    final StatWindow w = _window;
    return buildStatPeriodSummaryGrid(context, <StatPeriodSummary>[
      _periodSummary(
        t.stat_today,
        _todayChars,
        _todayMs,
        _lookup.today,
        _mined.today,
        _favorited.today,
        _favoritedSentences.today,
        contains: w.isToday,
      ),
      _periodSummary(
        t.stat_this_week,
        _weekChars,
        _weekMs,
        _lookup.week,
        _mined.week,
        _favorited.week,
        _favoritedSentences.week,
        contains: w.inWeek,
      ),
      _periodSummary(
        t.stat_this_month,
        _monthChars,
        _monthMs,
        _lookup.month,
        _mined.month,
        _favorited.month,
        _favoritedSentences.month,
        contains: w.inMonth,
      ),
      _periodSummary(
        t.stat_all_time,
        _allChars,
        _allMs,
        _lookup.all,
        _mined.all,
        _favorited.all,
        _favoritedSentences.all,
        contains: (String _) => true,
      ),
    ]);
  }

  StatPeriodSummary _periodSummary(
    String label,
    int chars,
    int ms,
    int lookup,
    int mined,
    int favorited,
    int favoritedSentences, {
    required bool Function(String dateKey) contains,
  }) {
    return StatPeriodSummary(
      label: label,
      primaryValue: _formatChars(chars),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(value: formatStatTime(ms)),
        StatSummaryLine(label: t.stat_lookup, value: '$lookup'),
        StatSummaryLine(label: t.stat_mined, value: '$mined'),
        StatSummaryLine(label: t.stat_favorited, value: '$favorited'),
        StatSummaryLine(
          label: t.stat_favorited_sentence,
          value: '$favoritedSentences',
        ),
      ],
    );
  }

  /// 时段卡 → 时段明细 sheet（阶段 1 统一组件；本页是阅读统计，明细只吃阅读域
  /// 切片 [_bookFacts]——域=行集，与 [studyGoalCharsForDay] 同原则）。
  Future<void> _showPeriodDetail(
    String label,
    bool Function(String dateKey) contains,
  ) async {
    final FushiDatabase db = appModelNoUpdate.database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: label,
      contains: contains,
      facts: _bookFacts,
      resolvers: StatPeriodDetailResolvers(
        titleOf: _statFactDisplayTitle,
        collectionOf: _statFactCollectionName,
        onEntryDelete: (StatPeriodEntryTarget t) =>
            deleteStatPeriodEntry(db, t),
        ambiguousTitlesOf: (String kind) => kind == kActivityMediaBook
            ? _ambiguousBookTitles
            : const <String>{},
      ),
    );
    if (deleted && mounted) await _loadFromDatabase();
  }

  /// 事实行 → 显示名（[_bookDisplayTitle] 的事实行版：override 书名上屏生效，
  /// 合集名走 sheet 组头不拼前缀）。
  String _statFactDisplayTitle(StatFact f) {
    final String? bookKey = f.mediaKey.isNotEmpty
        ? f.mediaKey
        : _bookKeyByTitle[f.title];
    if (bookKey == null) return f.title;
    return ReaderFushiSource.instance.overrideTitleForBookKey(bookKey) ??
        f.title;
  }

  /// 事实行 → 所属合集名（[_collectionNameForBook] 的事实行版，同一 v83 键契约）。
  String? _statFactCollectionName(StatFact f) {
    final String? bookKey = f.mediaKey.isNotEmpty
        ? f.mediaKey
        : _bookKeyByTitle[f.title];
    if (bookKey == null) return null;
    return statCollectionName(
      MediaKind.epub.compositeKey(_epubUidByBookKey[bookKey] ?? bookKey),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  /// TODO-1046: daily/weekly study goal card. Both goals 0 => no card at all
  /// (SizedBox.shrink), so an install that never set a goal sees zero visual
  /// change on the statistics page. Reuses the already-computed
  /// [_todayStudyChars] / [_weekStudyChars] aggregates (no extra DB query;
  /// study-domain numerators, BUG-1993).
  Widget _buildGoalPanel() {
    final int dailyGoal = appModelNoUpdate.readingGoalDailyChars;
    final int weeklyGoal = appModelNoUpdate.readingGoalWeeklyChars;
    if (dailyGoal <= 0 && weeklyGoal <= 0) {
      return const SizedBox.shrink();
    }

    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final List<Widget> rows = <Widget>[];
    if (dailyGoal > 0) {
      rows.add(_buildGoalRow(t.stat_goal_daily, _todayStudyChars, dailyGoal));
    }
    if (dailyGoal > 0 && weeklyGoal > 0) {
      rows.add(SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2));
    }
    if (weeklyGoal > 0) {
      rows.add(_buildGoalRow(t.stat_goal_weekly, _weekStudyChars, weeklyGoal));
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: FushiCard(
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
                FushiIconButton(
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final double? fraction = goalProgressFraction(read, goal);
    final bool reached = goalReached(read, goal);
    final Color barColor = reached ? colorScheme.tertiary : colorScheme.primary;
    final TextStyle? subStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);

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
              Text(
                t.stat_goal_reached,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.tertiary,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(dialogContext);
        return AlertDialog(
          title: Text(t.stat_goal_set),
          // helperText 让内容变高：横屏/小窗下用滚动兜底，不再顶到溢出。
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // BUG-1075：单位（与首页仪表盘目标对话框同一批 i18n key，两处编辑的是
                // 同一个持久化目标）。口径说明行已按用户要求删除——统计口径由实际计入的
                // 来源（阅读/漫画/视频字幕/游戏文本）自解释，不再在文案里逐项列举。
                TextField(
                  controller: dailyController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t.stat_goal_daily,
                    suffixText: t.stat_goal_unit_chars,
                  ),
                ),
                SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
                TextField(
                  controller: weeklyController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t.stat_goal_weekly,
                    suffixText: t.stat_goal_unit_chars,
                  ),
                ),
              ],
            ),
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final int dailyGoal = appModelNoUpdate.readingGoalDailyChars;
    final int charGoal = dailyGoal > 0 ? dailyGoal : _kDailyCharGoalFallback;
    // 目标环用学习域分子（BUG-1993，与目标卡 / 首页同口径）；下方 CPH 仍是
    // 阅读域字数 ÷ 阅读时长，量纲不混。
    final double charFrac = goalFraction(_todayStudyChars, charGoal);
    final int todayMinutes = _todayMs ~/ 60000;
    final double timeFrac = goalFraction(todayMinutes, _kDailyTimeGoalMinutes);
    // BUG-1107：今日速度同样过最小样本门槛（[computeCph] 内建，不足 1 分钟返回
    // null）——今日只有几十秒的记录时显示占位符，不外推爆表数字。
    final double? todayCph = computeCph(_todayChars, _todayMs);

    return _card(
      title: t.stat_today,
      trailing: Text(
        statTodayKey(),
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
                detail: '$_todayStudyChars/$charGoal',
                caption: t.stat_goal,
              ),
              StatRing(
                fraction: timeFrac,
                color: scheme.tertiary,
                trackColor: scheme.surfaceContainerHighest,
                value: '${(timeFrac * 100).round()}%',
                detail: formatStatTime(_todayMs),
                caption: t.stat_metric_time,
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          Row(
            children: <Widget>[
              Expanded(
                child: _miniStat(
                  t.stat_metric_speed,
                  todayCph != null && todayCph > 0 ? _formatCph(todayCph) : '-',
                ),
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

  Widget _miniStat(String label, String value) =>
      StatMiniTile(label: label, value: value);

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
                      child: _summaryTile(
                        t.stat_weighted_avg_speed,
                        _formatCph(s.weightedAvgCph),
                      ),
                    ),
                    Expanded(
                      child: _summaryTile(
                        t.stat_typical_day,
                        s.typicalDayCph != null
                            ? _formatCph(s.typicalDayCph!)
                            : '-',
                      ),
                    ),
                  ],
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _summaryTile(
                        t.stat_recent_active,
                        t.stat_format_days(n: s.recentActiveDays),
                      ),
                    ),
                    Expanded(child: _deltaTile(s.deltaPercent)),
                  ],
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _extremeTile(t.stat_fastest_day, s.fastestDay),
                    ),
                    Expanded(
                      child: _extremeTile(t.stat_slowest_day, s.slowestDay),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _summaryTile(String label, String value, {Color? valueColor}) =>
      StatSummaryTile(label: label, value: value, valueColor: valueColor);

  Widget _deltaTile(double? delta) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (delta == null) {
      return _summaryTile(t.stat_vs_prev, '-');
    }
    final bool up = delta >= 0;
    final String sign = up ? '+' : '';
    final Color color = up ? scheme.primary : scheme.error;
    return _summaryTile(
      t.stat_vs_prev,
      '$sign${delta.toStringAsFixed(0)}%',
      valueColor: color,
    );
  }

  Widget _extremeTile(String label, StatExtremeDay? day) {
    if (day == null) return _summaryTile(label, '-');
    final String date = day.dateKey.length >= 10
        ? day.dateKey.substring(5)
        : day.dateKey;
    return _summaryTile(label, '${_formatCph(day.cph)} · $date');
  }

  /// 「范围与趋势」折线卡：指标（字数/时长/速度）+ 粒度（日/周/月）切换 +
  /// 原始线 + 移动平均虚线（速度指标额外标异常点）。
  Widget _buildTrendPanel() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final List<StatTrendPoint> points = aggregateTrend(
      _dailyData,
      _trendGranularity,
    );
    final List<double> values = points
        .map((StatTrendPoint p) => trendMetricValue(p, _trendMetric))
        .toList();
    final int window = _trendGranularity == StatTrendGranularity.daily ? 7 : 3;
    final List<double> avgValues = movingAverage(values, window);
    final List<bool> anomalies = _trendMetric == StatTrendMetric.speed
        ? detectAnomalies(values)
        : List<bool>.filled(values.length, false);
    final List<String> xLabels = points
        .map((StatTrendPoint p) => p.label)
        .toList();
    final int labelEvery = _trendGranularity == StatTrendGranularity.daily
        ? 5
        : 1;
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
                .map(
                  (StatTrendMetric m) => FushiSelectableChip(
                    label: _metricLabel(m),
                    selected: _trendMetric == m,
                    onSelected: (_) => setState(() => _trendMetric = m),
                  ),
                )
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
    return FushiSelectableChip(
      label: label,
      selected: _trendGranularity == g,
      onSelected: (_) => setState(() => _trendGranularity = g),
    );
  }

  Widget _trendLegend() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.stat_bookshelf_compare,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            FushiSelectableChip(
              label: t.stat_sort_by_chars,
              selected: _bookSort == _BookSort.chars,
              onSelected: (_) => _changeBookSort(_BookSort.chars),
            ),
            FushiSelectableChip(
              label: t.stat_sort_by_time,
              selected: _bookSort == _BookSort.time,
              onSelected: (_) => _changeBookSort(_BookSort.time),
            ),
            FushiSelectableChip(
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
  /// DB 重新聚合刷新（TODO-1204 后续）。v92：带上 bookKey（tile 自带身份，legacy
  /// 无身份 tile 走 title 反查），DAO 同一事务连带删该书的 study_segments 并立按
  /// 身份的墓碑。
  Future<void> _confirmAndDeleteBook(_BookData book) async {
    final bool confirmed = await confirmDeleteStatistics(context, book.title);
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.deleteReadingStatisticsForTitle(
      book.title,
      bookKey: book.bookKey ?? _bookKeyByTitle[book.title],
    );
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

  /// 按书 tile 的所属合集名（书架同款「主合集」折叠归属，无则 null）。bookKey 优先
  /// 用 tile 自带身份，legacy 无身份 tile 才按 title 经 epub_books 反查；再经
  /// [_epubUidByBookKey] 换算拼 'epub|<uid>' 命中（v83 成员表键；换算不上按 bookKey
  /// 回退）。
  String? _collectionNameForBook(_BookData book) {
    final String? bookKey = book.bookKey ?? _bookKeyByTitle[book.title];
    if (bookKey == null) return null;
    return statCollectionName(
      MediaKind.epub.compositeKey(_epubUidByBookKey[bookKey] ?? bookKey),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  /// BUG-1018 (A1)：统计页书名列**渲染时**应用 override 书名（编辑对话框改名后
  /// 这里同步显示新名）。统计行仍按 DB 原 title 做计数键 / 删除（历史数据身份
  /// 不动），bookKey 优先取 tile 自带身份，legacy 无身份 tile 走 [_bookKeyByTitle]
  /// 反查。
  String _bookDisplayTitle(_BookData book) {
    final String? bookKey = book.bookKey ?? _bookKeyByTitle[book.title];
    if (bookKey == null) return book.title;
    return ReaderFushiSource.instance.overrideTitleForBookKey(bookKey) ??
        book.title;
  }

  Widget _buildBookTile(_BookData book) {
    // TODO-1204：查词/制卡计数按 title 聚合（无记录则 0）。
    final ({int lookups, int mines}) counter =
        _bookCounters[book.title] ?? (lookups: 0, mines: 0);
    final int favorites = _bookFavorites[book.title] ?? 0;
    final String? collectionName = _collectionNameForBook(book);
    // 进度条填充维度 = 当前排序维度（W1）：first 是当前排序下第一名（最大值）。
    final double topMetric = _bookData.isEmpty
        ? 0
        : _sortMetric(_bookData.first);
    final double fraction = bookProgressFraction(_sortMetric(book), topMetric);
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = FushiDesignTokens.of(context);

    return ContextMenuTrigger(
      // 移动端长按、桌面端右键都弹删除确认（书架同款交互）；右键那一半现在走绑定表。
      onInvoke: (Offset _) => _confirmAndDeleteBook(book),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onLongPress: () => _confirmAndDeleteBook(book),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _bookDisplayTitle(book),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (collectionName != null) ...[
                  SizedBox(height: tokens.spacing.gap / 4),
                  buildStatCollectionLabel(context, collectionName),
                ],
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
                    SizedBox(
                      width: tokens.spacing.gap + tokens.spacing.gap / 2,
                    ),
                    Text(
                      '${_formatChars(book.chars)} · ${formatStatTime(book.ms)}',
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
      ),
    );
  }
}

/// 「按书」一行的聚合：按 [StatFact.identityKey] 分组（有 bookKey 用 bookKey，
/// legacy 无身份行回退 title）。
class _BookData {
  _BookData({required this.title, this.bookKey});

  /// 展示 / 计数表键（查词、制卡、收藏计数表都按 title 聚合）。
  final String title;

  /// 稳定身份；legacy 无身份 tile 为 null，用 title 反查库表回退。
  final String? bookKey;
  int chars = 0;
  int ms = 0;

  /// 该书阅读速度（字/小时）。复用统一口径的 [computeCph]（内建最小样本时长
  /// 门槛，BUG-1107）；样本不足折叠为 0——排序/进度条把它当「无有效速度」，
  /// 不再让几秒脏行的书在速度维度霸榜。
  double get cph => computeCph(chars, ms) ?? 0;
}

/// 「今日」面板底部三宫格里的单个迷你统计（速度/连击/收藏）。
///
/// 手机窄屏下每格只有约 1/3 卡片宽，之前 [Text] 被 `maxLines: 1` 钉死会把
/// 中文标签和数值裁成省略号（BUG：手机统计页「好多显示不全的字」）。这里让
/// 数值与标签都能换行到 2 行，`ellipsis` 只作极端长文案的最后兜底。
class StatMiniTile extends StatelessWidget {
  const StatMiniTile({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            label,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 「速度摘要」卡里的半宽小格（加权均速 / 典型日 / 最快·最慢日 等）。
///
/// 同样为窄屏放开换行：`_extremeTile` 会塞进「速度 · 日期」这类复合值，半宽格
/// 单行必被裁；允许 2 行后完整可读，`ellipsis` 仅兜底极端长值。
class StatSummaryTile extends StatelessWidget {
  const StatSummaryTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: valueColor ?? scheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            label,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
