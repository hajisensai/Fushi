import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_hourly_breakdown.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_kpi_strip.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/pages/implementations/stat_ring.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/stat_source_totals.dart';
import 'package:fushi/src/pages/implementations/stat_summary.dart';
import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 「按书」列表的排序键：字数 / 时长 / 阅读速度（cph）。
enum _BookSort { chars, time, speed }

/// 「今天」环形进度在用户未设目标时的回退目标（仅用于可视化，不写库）。
const int _kDailyCharGoalFallback = 5000;
const int _kDailyTimeGoalMinutes = 60;

/// 宽屏断点：>= 此宽度时「分析」折叠区里的「今天」与「速度摘要」并排。
/// （内容整体不再限宽居中——四个 tab 统一全宽自适应，见 [_buildContent]。）
const double _kWideBreakpoint = 720;

class ReadingStatisticsPage extends BasePage {
  const ReadingStatisticsPage({
    super.key,
    this.embedded = false,
    this.rangeSelection,
  });

  /// true = 作为统计中心的一个 tab 嵌入（不套 FushiPageScaffold，动作行内联）。
  final bool embedded;

  /// 统计中心共享的范围选择；null（独立页）时本页自持一份。
  final ValueNotifier<StatRangeSelection>? rangeSelection;

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

  /// 阅读域会话流（`StatFacts.sessions` 的书切片，按结束时刻倒序）。
  List<StudySession> _sessions = <StudySession>[];

  /// 阅读域逐日合计：普通书与漫画同属阅读统计，视频和游戏由各自统计页负责。
  Map<StatBreakdownSource, Map<String, StatSourceTotals>> _sourceDaily =
      <StatBreakdownSource, Map<String, StatSourceTotals>>{};

  /// 「各来源」卡展示的所选范围合计（随 [_range]）。
  Map<StatBreakdownSource, StatSourceTotals> _breakdownTotals =
      <StatBreakdownSource, StatSourceTotals>{};

  /// 范围选择：统计中心传进来的共享那份，或独立页自持的一份。
  late final ValueNotifier<StatRangeSelection> _rangeSelection =
      widget.rangeSelection ??
      ValueNotifier<StatRangeSelection>(const StatRangeSelection());

  /// 阅读域逐日合计（范围图表 / 趋势 / 速度 / 所选范围卡 / 学习日历共用）。
  Map<String, StatDayData> _byDay = <String, StatDayData>{};

  /// 阅读域计数面原始行：按书的查词 / 制卡 / 收藏数跟随范围重算。
  List<LookupMiningCounterRow> _counterRows = <LookupMiningCounterRow>[];
  List<FavoriteWordRow> _favoriteRows = <FavoriteWordRow>[];
  List<(String, int)> _lookupEvents = const <(String, int)>[];
  List<(String, int)> _minedEvents = const <(String, int)>[];
  List<(String, int)> _favoritedEvents = const <(String, int)>[];
  List<(String, int)> _favoritedSentenceEvents = const <(String, int)>[];

  /// bookKey → 书架条目（按书行的封面走书架同一条缩略图链）。
  Map<String, MediaItem> _bookItemsByKey = <String, MediaItem>{};

  /// 当前范围：共享选择 × 本轮今日 × 阅读域最早有数据的一天。
  StatRange get _range => StatRange.resolve(
    _rangeSelection.value,
    todayKey: _window.todayKey,
    earliestKey: earliestStatDateKey(_byDay.keys),
  );

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

  // 所选范围内的逐日数据（升序、空日补 0）：趋势 / 速度摘要 / 日均的输入。
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

  // 连续天数（阅读域）。
  int _streak = 0;

  // 速度摘要（从所选范围的逐日数据纯函数算出）。
  SpeedSummary? _speedSummary;

  // 范围与趋势折线图的聚合粒度（日 / 周 / 月）与指标（字数 / 时长 / 速度）。
  StatTrendGranularity _trendGranularity = StatTrendGranularity.daily;
  StatTrendMetric _trendMetric = StatTrendMetric.chars;

  // 「按书」列表的排序键。
  _BookSort _bookSort = _BookSort.chars;

  @override
  void initState() {
    super.initState();
    _rangeSelection.addListener(_onRangeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAndLoad());
  }

  @override
  void dispose() {
    _midnightReload?.cancel();
    _rangeSelection.removeListener(_onRangeChanged);
    if (widget.rangeSelection == null) _rangeSelection.dispose();
    super.dispose();
  }

  /// 范围变了只重算范围派生量（纯内存，不重查 DB）。
  void _onRangeChanged() {
    if (!mounted || _loading) return;
    setState(_computeRangeAggregates);
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
      final StatFacts facts = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
      );
      _bookFacts = facts.dailyBooks.toList();
      _dailyFacts = facts.daily;
      _sessions = facts.sessions.where((StudySession s) => s.isBook).toList();
      _sourceDaily = aggregateStatSourceDaily(_bookFacts);
      // 加载事实时顺带取的书表：下面的 title→bookKey（合集归属 / legacy 行回退）
      // 与 bookKey→uid 换算复用同一批行，不再单独查。
      final List<EpubBookMeta> epubRows = facts.epubRows;
      _ambiguousBookTitles = ambiguousBookTitles(epubRows);
      _computeAggregates();
      // 计数面（查词 / 制卡 / 收藏）与事实面同一次加载：总览 tab 是跨域视图，
      // 它的四个数字必须恰好等于本 tab 与视频 tab 之和；三页各查一遍时，口径一漂
      // 就静默对不上。按 source 切片的判据只在 [StatCounterFacts] 里写一遍。
      final StatCounterFacts counterFacts = facts.counters;
      final List<FavoriteWordRow> favs = counterFacts.favoriteWordsFor(
        StatSourceKind.book,
      );
      _favorited = bucketActivityByDateKey(
        counterFacts.favoriteWordEvents(source: StatSourceKind.book),
        now,
      );
      _mined = bucketActivityByDateKey(
        counterFacts.minedEvents(source: StatSourceKind.book),
        now,
      );
      // 查词/制卡 per-book 计数：汇总用 lookupCount 分桶，per-book tile 按 title
      // 聚合（无书查词 title='' 跳过，只进汇总）。
      final List<LookupMiningCounterRow> counters = counterFacts
          .lookupCountersFor(StatSourceKind.book);
      _lookupEvents = counterFacts
          .lookupEvents(source: StatSourceKind.book)
          .toList();
      _minedEvents = counterFacts
          .minedEvents(source: StatSourceKind.book)
          .toList();
      _lookup = bucketActivityByDateKey(_lookupEvents, now);
      _favoritedEvents = counterFacts
          .favoriteWordEvents(source: StatSourceKind.book)
          .toList();
      _favoritedSentenceEvents = counterFacts
          .favoriteSentenceEvents(source: StatSourceKind.book)
          .toList();
      _counterRows = counters;
      _favoriteRows = favs;
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
        for (final EpubBookMeta r in epubRows)
          if (r.uid.isNotEmpty) r.bookKey: r.uid,
      };
      // 收藏语句按 source 分桶：非视频来源（书内 / 有声书 / 歌词）都归阅读统计。
      // BUG-893：写入端此前不带 dateKey，旧的 `dateKey != null` 过滤把所有书内收藏
      // 滤光 → 统计恒为 0。改用 `dateKey ?? statDateKey(createdAt)` 回退——createdAt
      // 恒非空，已存的无 dateKey 收藏也按创建日归桶（与写入端补 dateKey 双向修复）。
      _favoritedSentences = bucketActivityByDateKey(
        counterFacts.favoriteSentenceEvents(source: StatSourceKind.book),
        now,
      );
      _loadHourlyData(facts);
      _bookItemsByKey = <String, MediaItem>{
        for (final MediaItem item
            in ref
                    .read(fushiBooksProvider(JapaneseLanguage.instance))
                    .valueOrNull ??
                const <MediaItem>[])
          if (ReaderFushiSource.parseBookKey(item.mediaIdentifier)
              case final String key)
            key: item,
      };
      _computeRangeAggregates();
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
    // 窗口阈值只从 StatWindow 取（本周从周一至今日，上周取同期、近 30 天恰
    // 30 天），本页不再自己算日期；且只用本轮加载时的
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

    _byDay = dailyMap;

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
  }

  /// 范围派生量（纯内存，范围一变就重算，不重查 DB）：范围逐日数据 → 趋势 /
  /// 速度摘要 / 日均；来源合计；按书列表（字数 / 时长 / 查词 / 制卡 / 收藏全按
  /// 范围求和）。顶部时段卡与 KPI 的今日 / 本周是固定的当下视图，不在这里。
  void _computeRangeAggregates() {
    final StatRange range = _range;
    _dailyData = <StatDayData>[
      for (final String key in range.dayKeys)
        _byDay[key] ?? StatDayData(dateKey: key),
    ];
    _speedSummary = computeSpeedSummary(_dailyData);

    // 按书：与视频域同一套身份分组（BUG-2216，[groupStatFactsByIdentity]）——有
    // bookKey 按身份；legacy 无身份行（书已删 / 同名歧义反查失败）unique-title 吸收
    // 进唯一身份组，同一本书的 legacy 日行与 v92 段合成一个 tile；歧义独立成无身份
    // tile。title 取组首见快照作展示 / 计数键。只取范围内的日行。
    final Map<String, _BookData> bookMap = <String, _BookData>{};
    for (final StatIdentityGroup<StatFact> g in groupStatFactsByIdentity(
      _bookFacts.where((StatFact f) => range.contains(f.dateKey)),
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
    _bookData = bookMap.values.toList();
    _sortBookData();
    _bookCounters = aggregateStatCountersByTitle(
      _counterRows
          .where((LookupMiningCounterRow r) => range.contains(r.dateKey))
          .toList(),
    );
    _bookFavorites = aggregateStatFavoritesByTitle(
      _favoriteRows
          .where((FavoriteWordRow r) => range.contains(r.dateKey))
          .toList(),
    );

    // 阅读域来源合计（普通书 + 漫画）：所选范围内求和。
    _breakdownTotals = <StatBreakdownSource, StatSourceTotals>{
      for (final StatBreakdownSource source in const <StatBreakdownSource>[
        StatBreakdownSource.book,
        StatBreakdownSource.manga,
      ])
        source: sumStatSourceTotals(
          _sourceDaily[source] ?? const <String, StatSourceTotals>{},
          range.contains,
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

  /// 阅读速度展示：委托共享的 [formatStatCph]（时段卡 / 会话行同一口径）。
  static String _formatCph(double cph) => formatStatCph(cph);

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
        icon: FushiIcons.flag,
        tooltip: t.stat_goal_set,
        enabled: !_loading,
        onTap: _editGoals,
      ),
      FushiIconButton(
        icon: FushiIcons.refresh,
        tooltip: t.stat_refresh,
        enabled: !_loading,
        onTap: _syncAndLoad,
      ),
      FushiIconButton(
        icon: FushiIcons.deleteSweep,
        tooltip: t.stat_clear_all,
        enabled: !_loading,
        onTap: _confirmAndClearAll,
      ),
    ];
    final Widget body = buildStatPageBody(
      loading: _loading,
      error: _error,
      loadingBuilder: () =>
          buildLoading(size: 25, color: theme.colorScheme.primary),
      errorBuilder: (String error) => buildError(error: error),
      contentBuilder: _buildContent,
    );
    if (widget.embedded) return buildEmbeddedStatTab(context, actions, body);
    return FushiPageScaffold(
      title: t.reading_statistics,
      actions: actions,
      body: body,
    );
  }

  /// 页面骨架与总览 / 观看 / 游戏 tab 同一套（2026-10 统计中心重设计，
  /// [StatDashboardBody]）：关键指标区（目标面板 + 四张指标卡）→ 趋势栏（时间
  /// 窗口分段 + 日期翻页 → 范围时长图 → 所选范围卡 → 学习日历 → 「分析」折叠）
  /// → 明细栏（时段卡 → 最近会话 → 按书列表）。宽屏趋势 / 明细左右两栏，窄屏
  /// 单栏。KPI 条 / 趋势 / 今日环 + 速度摘要 / 来源分布 / 小时×格式仍在折叠区，
  /// 一个都没删。收尾留白与底部安全区（BUG-2440）由 [buildStatTailSliver] 补。
  Widget _buildContent() {
    final Widget hero = StatHero(
      lead: StatGoalPanel(
        goalChars: appModelNoUpdate.readingGoalDailyChars,
        progressChars: _todayStudyChars,
        weeklyGoalChars: appModelNoUpdate.readingGoalWeeklyChars,
        weeklyProgressChars: _weekStudyChars,
        onTap: _loading ? null : _editGoals,
      ),
      tiles: buildStatKpiTiles(context, computeStatKpis(_bookFacts, _window)),
    );
    if (_bookFacts.isEmpty) {
      return StatDashboardBody(
        hero: hero,
        emptyState: StatDashboardEmpty(message: t.stat_no_data),
        tail: buildStatTailSliver(context),
      );
    }
    return StatDashboardBody(
      hero: hero,
      tail: buildStatTailSliver(context),
      trend: <Widget>[..._buildRangeSection(), _buildAnalysisFold()],
      details: <Widget>[
        StatSectionHeader(title: t.stat_overview_periods),
        _buildSummaryCards(),
        buildStatSessionSection(
          context,
          sessions: _sessions,
          titleOf: _sessionTitle,
          collectionOf: _sessionCollectionName,
          coverOf: _sessionCover,
          onDelete: _deleteSession,
          onEdit: _editSession,
          onClearAll: _clearSessions,
        ),
        Padding(
          padding: EdgeInsets.only(
            bottom: FushiDesignTokens.of(context).spacing.gap,
          ),
          child: _buildByBookHeader(),
        ),
      ],
      detailSlivers: <Widget>[
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildBookTile(_bookData[index]),
            childCount: _bookData.length,
          ),
        ),
      ],
    );
  }

  /// 范围条「明细」→ 所选范围的时段明细 sheet（本页是阅读统计，明细只吃阅读域
  /// 切片 [_bookFacts]——域=行集，与 [studyGoalCharsForDay] 同原则）。时段谓词
  /// 就是范围条的 [StatRange.contains]（周 = 自然周，与所选范围卡同口径）。
  Future<void> _showRangeDetail(StatRange range) async {
    final FushiDatabase db = appModelNoUpdate.database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: formatStatRange(range),
      contains: range.contains,
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

  /// 范围区块（Niratan「Range」）：范围条（时间窗口分段 + 日期翻页）→ 范围
  /// 时长图 → 所选范围卡 → 学习日历，与总览 / 观看 / 游戏 tab 同序。范围驱动
  /// 下方趋势 / 速度摘要 / 来源分布 / 按书列表；时段卡恒为当下。
  List<Widget> _buildRangeSection() {
    final StatRange range = _range;
    return <Widget>[
      StatRangeBar(
        range: range,
        onChanged: (StatRangeSelection s) => _rangeSelection.value = s,
        trailing: StatRangeActions(
          onOpenDetail: () => unawaited(_showRangeDetail(range)),
        ),
      ),
      buildStatRangeChartSection(context, range, _byDay),
      buildStatRangeSummary(
        context,
        range,
        _byDay,
        extraLines: <StatSummaryLine>[
          if (statBookCphOf(_bookFacts, range.contains) case final String cph)
            StatSummaryLine(label: t.stat_reading_speed, value: cph),
          ...buildStatRangeCounterLines(
            range,
            lookups: _lookupEvents,
            mined: _minedEvents,
            favorited: _favoritedEvents,
            favoritedSentences: _favoritedSentenceEvents,
          ),
        ],
      ),
      buildStatRangeCalendarSection(
        context,
        byDay: _byDay,
        now: _window.now,
        onDaySelected: (String dateKey) => _rangeSelection.value =
            StatRangeSelection(mode: StatRangeMode.day, anchorKey: dateKey),
      ),
    ];
  }

  /// 「分析」折叠区：KPI 条 → 趋势 → 今日环 + 速度摘要 → 来源分布 → 小时×格式。
  Widget _buildAnalysisFold() {
    final double card = FushiDesignTokens.of(context).spacing.card;
    return StatAnalysisFold(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(card, card, card, card),
          child: _buildKpiStrip(),
        ),
        Padding(
          padding: EdgeInsets.only(left: card, right: card, bottom: card),
          child: _buildTrendPanel(),
        ),
        Padding(
          padding: EdgeInsets.only(left: card, right: card, bottom: card),
          child: _buildMidSection(),
        ),
        _buildSourceBreakdown(),
        buildStatHourlyFormatChartSection(context, _hourly),
      ],
    );
  }

  /// 「今天」环 + 「速度摘要」：所在栏够宽（≥ [_kWideBreakpoint]）并排，否则堆叠。
  Widget _buildMidSection() {
    final double gap = FushiDesignTokens.of(context).spacing.card;
    final Widget today = _buildTodayPanel();
    final Widget summary = _buildSpeedSummaryPanel();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= _kWideBreakpoint) {
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
      },
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
    // BUG-892 后续：日均字数用与范围图表同一窗口的活跃日均值（[_dailyData] 即所选
    // 范围的逐日数据），不再用终身均值——后者被历史低产日拉低、与同屏指标对不上。
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
          icon: FushiIcons.streak,
          value: t.stat_format_days(n: _streak),
          label: t.stat_streak,
        ),
        StatKpiItem(
          icon: FushiIcons.calendar,
          value: formatStatChars(_todayChars),
          label: t.stat_today,
        ),
        StatKpiItem(
          icon: FushiIcons.trendingUp,
          value: formatStatChars(_weekChars),
          label: t.stat_this_week,
          delta: weekDelta,
          deltaUp: weekPct == null ? true : weekPct >= 0,
        ),
        StatKpiItem(
          icon: FushiIcons.lineChart,
          value: formatStatChars(dailyAvgChars),
          label: t.stat_daily_average,
        ),
      ],
    );
  }

  /// 卡片外壳：与图表卡 / 日历卡同一种 [StatSectionCard]（标题 + 可选 trailing
  /// + 内容）；外边距由调用方给（折叠区内已自带横向留白）。
  Widget _card({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return StatSectionCard(
      title: title,
      trailing: trailing,
      margin: EdgeInsets.zero,
      child: child,
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
      // 窗口 = 页面范围条（此前卡内自带今日 / 本周 / 本月 / 全部四颗 chip，与
      // 范围条重复且口径不一）。
      child: _card(
        title: t.stat_source_breakdown,
        trailing: Text(
          formatStatRange(_range),
          textAlign: TextAlign.right,
          overflow: TextOverflow.ellipsis,
          style: tokens.type.metadata.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  /// 单个来源一行：图标 + 名称 + 「字数 · 时长（· 页数）」。
  Widget _breakdownRow(StatBreakdownSource source, StatSourceTotals totals) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label) = switch (source) {
      StatBreakdownSource.book => (FushiIcons.books, t.home_filter_read),
      StatBreakdownSource.manga => (FushiIcons.manga, t.manga_library),
      StatBreakdownSource.video => (FushiIcons.video, t.home_filter_watch),
      StatBreakdownSource.game => (FushiIcons.game, t.home_filter_game),
    };
    final List<String> metrics = <String>[
      formatStatChars(totals.chars),
      formatStatTime(totals.timeMs),
      // 页数只有漫画有；0 页不显示（未翻页的会话只贡献时长）。
      if (totals.pages > 0) t.stat_format_pages(n: totals.pages),
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Row(
        children: <Widget>[
          FushiIcon(icon, size: 18, color: scheme.onSurfaceVariant),
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
    final String? cph = formatStatCphOf(chars, ms);
    return StatPeriodSummary(
      label: label,
      // 主值 = 学习时长，与观看 / 游戏 / 总览三个 tab 同口径（用户 2026-09-08
      // 「统计全改成游戏那种」时骨架已统一，主值口径漏了这一处：四张同形卡里只有
      // 阅读卡以字数打头，横着看四个 tab 时首行数字不可比）。字数降为首条副行。
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(value: formatStatChars(chars)),
        // 速度（字/时）紧跟字数：用户 2026-09-12 要求顶部方框直接给出每小时字数。
        StatSummaryLine(
          label: t.stat_reading_speed,
          value: cph ?? kStatEmptyValue,
        ),
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

  /// 目标编辑：表单本体是统计页共享件 [showStatGoalEditDialog]（统计中心总览 tab
  /// 编辑的是同一个持久化目标）。保存后 setState 重跑 sliver build，目标卡立刻
  /// 出现/更新/消失。
  Future<void> _editGoals() async {
    final bool saved = await showStatGoalEditDialog(context, appModelNoUpdate);
    if (saved && mounted) setState(() {});
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
    final StatChartColors chartColors = statChartColorsOf(context);
    // Apple：环的底轨是 systemFill（「健康」活动环的空轨），不是更亮一档的面色。
    final Color ringTrack = isGlassDesign(context)
        ? appleColorsOf(context).fill
        : scheme.surfaceContainerHighest;

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
                color: chartColors.series,
                trackColor: ringTrack,
                value: '${(charFrac * 100).round()}%',
                detail: '$_todayStudyChars/$charGoal',
                caption: t.stat_goal,
              ),
              StatRing(
                fraction: timeFrac,
                color: chartColors.compare,
                trackColor: ringTrack,
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
    if (delta == null) {
      return _summaryTile(t.stat_vs_prev, '-');
    }
    final bool up = delta >= 0;
    final String sign = up ? '+' : '';
    final StatChartColors chartColors = statChartColorsOf(context);
    final Color color = up ? chartColors.up : chartColors.down;
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
    // 横轴标签稀疏到约 7 个：范围可以是一年 / 全部历史，逐日 365 个点不能每 5
    // 个标一次。
    final int labelEvery = math.max(1, (points.length / 7).ceil());
    final TextStyle labelStyle = tokens.type.metadata.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final StatTrendMetric metric = _trendMetric;
    final StatChartColors chartColors = statChartColorsOf(context);

    return _card(
      title: t.stat_range_and_trend,
      // 标注 = 图上真实画的范围（此前标的是全部历史首末日，图却只画近 30 天）。
      trailing: Text(
        formatStatRange(_range),
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
          // 日 / 周 / 月是互斥的一组粒度，用分段控件而不是三颗 chip（MD3
          // 连接按钮组 / Apple 液态玻璃分段，「健康」App 的 D·W·M 同形）。
          FushiSegmentedButton<StatTrendGranularity>(
            showSelectedIcon: false,
            segments: <ButtonSegment<StatTrendGranularity>>[
              _granSegment(t.stat_trend_daily, StatTrendGranularity.daily),
              _granSegment(t.stat_trend_weekly, StatTrendGranularity.weekly),
              _granSegment(t.stat_trend_monthly, StatTrendGranularity.monthly),
            ],
            selected: <StatTrendGranularity>{_trendGranularity},
            onSelectionChanged: (Set<StatTrendGranularity> v) =>
                setState(() => _trendGranularity = v.first),
          ),
          SizedBox(height: tokens.spacing.card),
          SizedBox(
            height: 200,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatLineChartPainter(
                series: <StatLineSeries>[
                  StatLineSeries(values: values, color: chartColors.series),
                  StatLineSeries(
                    values: avgValues,
                    color: chartColors.compare,
                    strokeWidth: 1.5,
                    dashed: true,
                  ),
                ],
                xLabels: xLabels,
                anomalies: anomalies,
                anomalyColor: chartColors.down,
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

  ButtonSegment<StatTrendGranularity> _granSegment(
    String label,
    StatTrendGranularity g,
  ) => ButtonSegment<StatTrendGranularity>(value: g, label: Text(label));

  Widget _trendLegend() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final StatChartColors chartColors = statChartColorsOf(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Wrap(
      spacing: tokens.spacing.card,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        _legendItem(chartColors.series, _metricLabel(_trendMetric), style),
        _legendItem(chartColors.compare, t.stat_speed_avg, style),
        if (_trendMetric == StatTrendMetric.speed)
          _legendItem(chartColors.down, t.stat_speed_anomaly, style),
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

  /// 「按书」区块头：与「时段明细」等同一种 [StatSectionHeader]，副标题是
  /// 所选范围，排序 chip 挂在标题下。
  Widget _buildByBookHeader() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return StatSectionHeader(
      title: t.stat_bookshelf_compare,
      subtitle: formatStatRange(_range),
      below: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
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

  /// 会话行展示名：段 title 快照 → override 书名（与 [_bookDisplayTitle] 同判据）。
  String _sessionTitle(StudySession s) =>
      ReaderFushiSource.instance.overrideTitleForBookKey(s.mediaKey) ?? s.title;

  /// 会话行封面：段 mediaKey 即 bookKey，与「按书」行 [_buildBookTile] 同一张
  /// 书条目表、同一条书自己的缩略图链。
  ImageProvider? _sessionCover(StudySession s) {
    final MediaItem? item = _bookItemsByKey[s.mediaKey];
    return item == null
        ? null
        : resolveMediaCoverImage(
            kind: MediaKind.epub,
            book: item,
            appModel: appModelNoUpdate,
            decodeWidth: kActivityCoverDecodePixelWidth,
          );
  }

  /// 会话行的所属合集名（BUG-2417：合集里段 title 是分册名，行上得写清是哪套
  /// 书）。会话自带 bookKey 身份（段 mediaKey），经 [_epubUidByBookKey] 换算拼
  /// 'epub|<uid>'，与 [_collectionNameForBook] 同一 v83 键契约。
  String? _sessionCollectionName(StudySession s) => s.mediaKey.isEmpty
      ? null
      : statCollectionName(
          MediaKind.epub.compositeKey(
            _epubUidByBookKey[s.mediaKey] ?? s.mediaKey,
          ),
          _primaryCollectionByEntry,
          _collectionNamesById,
        );

  /// 删一次会话：段写零（同步安全），再从 DB 重新聚合。
  Future<void> _deleteSession(StudySession s) async {
    await deleteStudySession(appModelNoUpdate.database, s);
    if (mounted) await _loadFromDatabase();
  }

  /// 改一次会话（日期 / 字数）：走会话编辑的唯一入口（先在 StudyClock 上退役 uid
  /// 再写库），再整页重聚合——改完日期的会话要重新按 gap 归并、重新排序。
  Future<void> _editSession(StudySession s, StudySessionEdit edit) async {
    await applyStudySessionEdit(appModelNoUpdate.database, s, edit);
    if (mounted) await _loadFromDatabase();
  }

  /// 清除这一批会话记录（防呆确认已在按钮里做掉）：只清会话事实，收藏 / 制卡历史 /
  /// 查词计数一个都不动（与逐条删同一边界）。
  Future<void> _clearSessions(List<StudySession> batch) async {
    await deleteStudySessions(appModelNoUpdate.database, batch);
    if (mounted) await _loadFromDatabase();
  }

  /// 点按书 tile → 这本书的会话列表 sheet（legacy 无身份 tile 按 title 反查；
  /// 反查不到就没有会话——legacy 日行本来也没有会话）。
  Future<void> _showBookSessions(_BookData book) async {
    final String? bookKey = book.bookKey ?? _bookKeyByTitle[book.title];
    final List<StudySession> sessions = bookKey == null
        ? const <StudySession>[]
        : _sessions.where((StudySession s) => s.mediaKey == bookKey).toList();
    final bool deleted = await showStatSessionsSheet(
      context,
      title: _bookDisplayTitle(book),
      sessions: sessions,
      titleOf: _sessionTitle,
      collectionOf: _sessionCollectionName,
      coverOf: _sessionCover,
      onDelete: (StudySession s) =>
          deleteStudySession(appModelNoUpdate.database, s),
      onEdit: (StudySession s, StudySessionEdit edit) =>
          applyStudySessionEdit(appModelNoUpdate.database, s, edit),
      onClearAll: (List<StudySession> batch) =>
          deleteStudySessions(appModelNoUpdate.database, batch),
    );
    if (deleted && mounted) await _loadFromDatabase();
  }

  /// 「按书」一行（游戏页同款 [buildStatMediaRow]）：字数 · 会话数 · 速度 / 查词 ·
  /// 制卡 · 收藏，右侧时长；点按进该书的会话 sheet，长按 / 右键删该书统计。
  Widget _buildBookTile(_BookData book) {
    // TODO-1204：查词/制卡计数按 title 聚合（无记录则 0）。
    final ({int lookups, int mines}) counter =
        _bookCounters[book.title] ?? (lookups: 0, mines: 0);
    final int favorites = _bookFavorites[book.title] ?? 0;
    final String? bookKey = book.bookKey ?? _bookKeyByTitle[book.title];
    final int sessionCount = bookKey == null
        ? 0
        : _sessions.where((StudySession s) => s.mediaKey == bookKey).length;
    final String speed = book.cph > 0 ? ' · ${_formatCph(book.cph)}' : '';
    final MediaItem? item = bookKey == null ? null : _bookItemsByKey[bookKey];
    return buildStatMediaRow(
      context,
      icon: FushiIcons.books,
      cover: item == null
          ? null
          : resolveMediaCoverImage(
              kind: MediaKind.epub,
              book: item,
              appModel: appModelNoUpdate,
              decodeWidth: kActivityCoverDecodePixelWidth,
            ),
      title: _bookDisplayTitle(book),
      collectionName: _collectionNameForBook(book),
      meta:
          '${formatStatChars(book.chars)} · '
          '${t.stat_sessions_count(n: sessionCount)}$speed',
      meta2:
          '${t.stat_lookup}: ${counter.lookups} · ${t.stat_mined}: ${counter.mines} · ${t.stat_favorited}: $favorites',
      trailing: formatStatTime(book.ms),
      onTap: () => unawaited(_showBookSessions(book)),
      onDelete: () => unawaited(_confirmAndDeleteBook(book)),
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
    // M3E：饱和 tonal 色块（secondaryContainer + onSecondaryContainer）；墨水屏
    // 回落中性最高层，Apple 保持 tertiaryGrouped 嵌套底。
    final bool apple = isGlassDesign(context);
    final bool tonal = !apple && !isEinkTheme(context);
    final Color valueColor = tonal
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    final Color labelColor = tonal
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Container(
      margin: EdgeInsets.only(right: tokens.spacing.gap),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      decoration: BoxDecoration(
        // Apple：卡里再嵌一层用 tertiarySystemGroupedBackground，比卡底高一档
        // 而不是跳到最亮的面色。
        color: apple
            ? appleColorsOf(context).tertiaryGroupedBackground
            : tonal
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
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
            style: context.fushiType.titleMediumEmphasized.tabular.copyWith(
              color: valueColor,
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
            ).textTheme.bodySmall?.copyWith(color: labelColor),
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
