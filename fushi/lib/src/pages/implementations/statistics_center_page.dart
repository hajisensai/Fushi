import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/game_statistics_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_overview.dart';
import 'package:fushi/src/pages/implementations/stat_day_reset_hour_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 统计中心的 tab（阶段 2：三个独立统计页收进一个入口）。排行榜 2026-09-28 曾是第 5 个
/// tab，2026-10-01 抽成首页统计中心入口旁的独立页（[LeaderboardPage]）。
enum StatsCenterTab { overview, reading, video, game }

/// 统计中心（阶段 2，统计中心大改造）：总览 + 阅读/观看/游戏三域 tab。
///
/// 三域 tab 直接复用现有统计页的 `embedded` 模式（页面本体一行没重写——不从零
/// 重写现有功能）；总览 tab 是唯一新内容：跨域今日学习目标 + 四张跨域时段卡
/// （点开完整日面的时段明细 sheet）。各媒体首页的柱状图入口统一指到这里的
/// 对应 tab，原独立统计页路由保留（不破坏既有导航）。
class StatisticsCenterPage extends BasePage {
  const StatisticsCenterPage({
    super.key,
    this.initialTab = StatsCenterTab.overview,
  });

  /// 打开时落在哪个 tab（各媒体首页入口传自己的域）。
  final StatsCenterTab initialTab;

  @override
  BasePageState<StatisticsCenterPage> createState() =>
      _StatisticsCenterPageState();
}

class _StatisticsCenterPageState extends BasePageState<StatisticsCenterPage> {
  /// 四个 tab 共享的范围选择（Niratan 式「Range」）：切 tab 不丢范围，各 tab 按
  /// 自己域的最早日解析成 [StatRange]。只活在本页（不持久化），重进统计中心回到
  /// 默认「本月」。
  final ValueNotifier<StatRangeSelection> _rangeSelection =
      ValueNotifier<StatRangeSelection>(const StatRangeSelection());

  @override
  void dispose() {
    _rangeSelection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v105：统计按 Profile 隔离——页头点明当前看的是哪个 Profile 的数字，否则
    // 切个 Profile「统计全没了」无从解释。名字取 ProfileViewModel 的激活项
    // （它在 _load 前是 -1 哨兵，此时不显示副标题，等它装好再重建）。
    final String? profileName =
        ref.watch(profileViewModelProvider).activeProfile?.name;
    return FushiPageScaffold(
      title: t.stat_center_title,
      subtitle: profileName == null
          ? null
          : t.stat_center_profile_scope(name: profileName),
      actions: <Widget>[
        // 「今日」重置整点是三域学习段共用的 dateKey 输入，所以入口放在统计中心
        // 页头而不是某一域的设置页；宽窗展开成「图标 + 文字」药丸（label），窄窗
        // 回落为纯图标、tooltip 仍是完整标题。
        FushiIconButton(
          icon: Icons.update_outlined,
          tooltip: t.stat_center_day_reset_hour,
          label: t.stat_center_day_reset_action,
          onTap: () =>
              showStatDayResetHourDialog(context, ref.read(appProvider)),
        ),
      ],
      body: DefaultTabController(
        length: StatsCenterTab.values.length,
        initialIndex: widget.initialTab.index,
        child: Column(
          children: <Widget>[
            FushiTabBar(
              tabs: <Widget>[
                Tab(text: t.stat_center_tab_overview),
                Tab(text: t.home_filter_read),
                Tab(text: t.home_filter_watch),
                Tab(text: t.home_filter_game),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _StatsOverviewTab(rangeSelection: _rangeSelection),
                  ReadingStatisticsPage(
                    embedded: true,
                    rangeSelection: _rangeSelection,
                  ),
                  VideoStatisticsPage(
                    embedded: true,
                    rangeSelection: _rangeSelection,
                  ),
                  GameStatisticsPage(
                    embedded: true,
                    rangeSelection: _rangeSelection,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 总览 tab：跨域「今日目标」进度 + 四张跨域时段卡。数据一次 [loadStatFacts]
/// 取完整日面；目标口径与首页/阅读统计页同函数（[studyGoalCharsForDay]，
/// BUG-1993）。
class _StatsOverviewTab extends ConsumerStatefulWidget {
  const _StatsOverviewTab({required this.rangeSelection});

  /// 统计中心共享的范围选择（见 [StatRangeBar]）。
  final ValueNotifier<StatRangeSelection> rangeSelection;

  @override
  ConsumerState<_StatsOverviewTab> createState() => _StatsOverviewTabState();
}

class _StatsOverviewTabState extends ConsumerState<_StatsOverviewTab> {
  bool _loading = true;
  String? _error;

  /// 完整跨域日面（`StatFacts.daily`）：目标分子的输入（目标是跨域的每日学习
  /// 目标，不随媒体筛选变口径），也是重新筛选的源。
  List<StatFact> _allDaily = <StatFact>[];

  /// 当前媒体筛选（[_filter]）下的日面：时段卡 / 关键指标 / 范围区块都吃它。
  /// 「全部」档与 [_allDaily] 同一批行。
  List<StatFact> _daily = <StatFact>[];

  /// 跨域会话流（`StatFacts.sessions`：书 / 视频 / 游戏混排，按结束时刻倒序）。
  List<StudySession> _allSessions = <StudySession>[];

  /// 当前筛选下的会话流。
  List<StudySession> _sessions = <StudySession>[];

  /// 本轮加载的计数面（查词 / 制卡 / 收藏），换筛选时按 [StatMediaFilterX.source]
  /// 重新切——与三个域 tab 同一个切分判据。
  StatCounterFacts _counters = StatCounterFacts.empty;

  /// 总览的媒体类型筛选（2026-10 重设计）：只活在本 tab，重进统计中心回到「全部」。
  StatMediaFilter _filter = StatMediaFilter.all;
  Map<String, String> _bookKeyByTitle = <String, String>{};
  Set<String> _ambiguousBookTitles = <String>{};
  Map<String, String> _epubUidByBookKey = <String, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<int, String> _collectionNamesById = <int, String>{};
  List<GalgameEntry> _games = <GalgameEntry>[];

  /// 会话行封面的两张表：书条目（键 = 段 mediaKey，bookKey / 有声书 srt uid
  /// 两种书身份都收，与 [_openEntry] 同一判据）与视频封面路径（键 = bookUid）。
  /// 游戏封面直接从 [_games] 取。
  Map<String, MediaItem> _bookItemsByKey = <String, MediaItem>{};
  Map<String, String> _videoCoverPathByUid = <String, String>{};

  /// 跨域计数面分桶（阅读 + 视频 + 游戏三个来源之和）。时段卡之前只有时长 / 字数，
  /// 制卡与查词这两个每天都在动的数字在总览上一个都看不到，只能逐个 tab 翻——
  /// 现在与三个域 tab 的时段卡逐行同形。
  StatActivityBuckets _lookup = StatActivityBuckets();
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  /// 本轮加载时的统计窗口（「今日」只有一个，BUG-2219）。
  StatWindow _window = StatWindow(DateTime.now());

  /// 跨域逐日合计（范围图表 / 所选范围卡 / 学习日历共用）。
  Map<String, StatDayData> _byDay = <String, StatDayData>{};

  /// 跨域查词 / 制卡事件（dateKey, 次数），所选范围卡按范围求和。
  List<(String, int)> _lookupEvents = const <(String, int)>[];
  List<(String, int)> _minedEvents = const <(String, int)>[];

  @override
  void initState() {
    super.initState();
    widget.rangeSelection.addListener(_onRangeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    widget.rangeSelection.removeListener(_onRangeChanged);
    super.dispose();
  }

  void _onRangeChanged() {
    if (mounted) setState(() {});
  }

  /// 按 [_filter] 从本轮加载的完整数据重切一遍（不重查库）。
  ///
  /// 「全部」= 不传 source（三个域 tab 各传自己的那一个），所以总览的数字恒等于
  /// 三个 tab 之和；单域档与对应域 tab 同一个 source——同一批行、同一个分桶函数，
  /// 没有第二条口径。分桶的「现在」取本轮窗口（[_window]，BUG-2219）。
  void _applyFilter() {
    final StatSourceKind? source = _filter.source;
    final DateTime now = _window.now;
    _daily = filterStatFacts(_allDaily, _filter);
    _byDay = sumStatDaysByKey(_daily);
    _sessions = filterStudySessions(_allSessions, _filter);
    _lookupEvents = _counters.lookupEvents(source: source).toList();
    _minedEvents = _counters.minedEvents(source: source).toList();
    _lookup = bucketActivityByDateKey(_lookupEvents, now);
    _mined = bucketActivityByDateKey(_minedEvents, now);
    _favorited = bucketActivityByDateKey(
      _counters.favoriteWordEvents(source: source),
      now,
    );
    _favoritedSentences = bucketActivityByDateKey(
      _counters.favoriteSentenceEvents(source: source),
      now,
    );
  }

  void _selectFilter(StatMediaFilter filter) {
    if (filter == _filter) return;
    setState(() {
      _filter = filter;
      _applyFilter();
    });
  }

  /// 加载失败后的重试：先回到加载态（按钮不可连点），再重新聚合。
  void _retryLoad() {
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(_load());
  }

  /// 当前范围：共享选择 × 本 tab 的今日 × 跨域最早有数据的一天。
  StatRange get _range => StatRange.resolve(
    widget.rangeSelection.value,
    todayKey: _window.todayKey,
    earliestKey: earliestStatDateKey(_byDay.keys),
  );

  Future<void> _load() async {
    try {
      final AppModel appModel = ref.read(appProvider);
      final FushiDatabase db = appModel.database;
      final StatFacts facts = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
      );
      _allDaily = facts.daily;
      _allSessions = facts.sessions;
      _counters = facts.counters;
      _window = StatWindow(DateTime.now());
      _applyFilter();
      // BUG-2216：同名 ≥2 本的 title 不进反查表（贴给任意一本都是错贴）。
      _bookKeyByTitle = uniqueBookKeyByTitle(facts.epubRows);
      _ambiguousBookTitles = ambiguousBookTitles(facts.epubRows);
      _epubUidByBookKey = <String, String>{
        for (final EpubBookMeta r in facts.epubRows)
          if (r.uid.isNotEmpty) r.bookKey: r.uid,
      };
      _collectionNamesById = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
      };
      _primaryCollectionByEntry = await db.getPrimaryCollectionIdByEntry();
      _games = await appModel.galgameRepo.load();
      _videoCoverPathByUid = <String, String>{
        for (final VideoBookRow b in await VideoBookRepository(db).listAll())
          if (b.coverPath case final String path when path.isNotEmpty)
            b.bookUid: path,
      };
      _bookItemsByKey = <String, MediaItem>{
        for (final MediaItem item
            in ref
                    .read(fushiBooksProvider(JapaneseLanguage.instance))
                    .valueOrNull ??
                const <MediaItem>[])
          if (ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
                  ReaderFushiSource.parseSrtBookUid(item.mediaIdentifier)
              case final String key)
            key: item,
      };
      _error = null;
    } catch (error, stack) {
      ErrorLogService.instance.log('StatsOverviewTab.load', error, stack);
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 四个 tab 的动作行**逐颗同形**（用户 2026-09-10「所有界面都要统一」）：
    // 目标 → 刷新 → 清空全部统计。此前是四种排列（总览无清空、观看 / 游戏无目标），
    // 横着切 tab 时按钮在原地变意思。目标入口的理由与 BUG-970 同：没有常驻入口就
    // 永远设不了第一个目标（2026-10 起总览的目标面板未设时也显示引导、可点）。
    // 本 tab 是跨域视图，所以这里的「清空」= 三个域一起清（[_confirmAndClearAll]）。
    final List<Widget> actions = <Widget>[
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
        onTap: () => unawaited(_load()),
      ),
      FushiIconButton(
        icon: Icons.delete_sweep_outlined,
        tooltip: t.stat_clear_all,
        enabled: !_loading,
        onTap: _confirmAndClearAll,
      ),
    ];
    return buildEmbeddedStatTab(context, actions, _buildBody(tokens));
  }

  Widget _buildBody(FushiDesignTokens tokens) {
    if (_loading) {
      return const FushiLoadingView();
    }
    if (_error != null) {
      // 2026-10 体验优化：不再把异常原文（英文堆栈片段）直接甩给用户；原文已在
      // [_load] 写进错误日志，这里显示本地化的「加载出错」+ 重试。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.error_load_failed, style: tokens.type.metadata),
            SizedBox(height: tokens.spacing.gap),
            FushiTextButton.icon(
              key: const ValueKey<String>('stat-overview-retry'),
              onPressed: _retryLoad,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry),
            ),
          ],
        ),
      );
    }
    return _buildOverviewBody(tokens);
  }

  /// 总览主体：数据切片 + 各区块的装配；排布（宽 / 窄、错峰进场、空数据态）
  /// 由 [StatDashboardBody] 一处决定（与三个域 tab 同一套），信息架构见那里的文档。
  Widget _buildOverviewBody(FushiDesignTokens tokens) {
    final StatWindow w = _window;
    final StatRange range = _range;
    final bool empty = _daily.isEmpty && _sessions.isEmpty;
    final Widget filterBar = StatMediaFilterBar(
      selected: _filter,
      onChanged: _selectFilter,
    );
    final AppModel appModel = ref.read(appProvider);
    final Widget hero = StatHero(
      lead: StatGoalPanel(
        goalChars: appModel.readingGoalDailyChars,
        progressChars: studyGoalCharsForDay(_allDaily, w.todayKey),
        weeklyGoalChars: appModel.readingGoalWeeklyChars,
        weeklyProgressChars: studyGoalCharsForWeek(_allDaily, w),
        onTap: _loading ? null : () => unawaited(_editGoals()),
      ),
      tiles: buildStatKpiTiles(context, computeStatKpis(_daily, w)),
    );
    if (empty) {
      return StatDashboardBody(
        replayKey: _filter,
        header: filterBar,
        hero: hero,
        emptyState: StatDashboardEmpty(message: t.stat_overview_empty),
        tail: buildStatTailSliver(context),
      );
    }
    return StatDashboardBody(
      replayKey: _filter,
      header: filterBar,
      hero: hero,
      tail: buildStatTailSliver(context),
      trend: <Widget>[
        StatRangeBar(range: range, onChanged: _selectRange),
        buildStatRangeChartSection(context, range, _byDay),
        buildStatRangeSummary(
          context,
          range,
          _byDay,
          extraLines: <StatSummaryLine>[
            if (statBookCphOf(_daily, range.contains) case final String cph)
              StatSummaryLine(label: t.stat_reading_speed, value: cph),
            StatSummaryLine(
              label: t.stat_lookup,
              value: '${sumStatEventsInRange(_lookupEvents, range)}',
            ),
            StatSummaryLine(
              label: t.stat_mined,
              value: '${sumStatEventsInRange(_minedEvents, range)}',
            ),
          ],
        ),
        buildStatRangeCalendarSection(
          context,
          byDay: _byDay,
          now: w.now,
          onDaySelected: _selectDay,
        ),
      ],
      details: <Widget>[
        StatSectionHeader(title: t.stat_overview_periods),
        _buildSummaryCards(w),
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
      ],
    );
  }

  /// 目标编辑：与阅读统计 tab 同一份表单、同一个持久化目标。
  Future<void> _editGoals() async {
    final bool saved = await showStatGoalEditDialog(
      context,
      ref.read(appProvider),
      recentDailyAverage:
          statRecentDailyAverageChars(_allDaily, _window.lastDayKeys(7)),
    );
    if (saved && mounted) setState(() {});
  }

  void _selectRange(StatRangeSelection selection) =>
      widget.rangeSelection.value = selection;

  /// 日历点某天 → 范围切到那一天（Niratan 同款：日历是范围的锚点选择器）。
  void _selectDay(String dateKey) => widget.rangeSelection.value =
      StatRangeSelection(mode: StatRangeMode.day, anchorKey: dateKey);

  /// 会话行展示名：与时段明细的 [_entryTitle] 同判据（游戏走库内显示名、书走
  /// override 书名），只是输入是会话而非事实行。
  String _sessionTitle(StudySession s) {
    if (s.isGame) {
      final GalgameEntry? entry = findGalgameForActivity(
        _games,
        mediaKey: s.mediaKey,
        title: s.title,
      );
      return displayTitleForGame(entry: entry, rawTitle: s.title);
    }
    if (s.isBook) {
      return ReaderFushiSource.instance.overrideTitleForBookKey(s.mediaKey) ??
          s.title;
    }
    return s.title;
  }

  /// 会话行封面（三域混排时最快的辨认线索）：与三个域 tab 的会话行 / 「按媒体」
  /// 行同一条 [resolveMediaCoverImage] 解析链，只是按会话所属域分派。
  ImageProvider? _sessionCover(StudySession s) {
    if (s.isGame) {
      return resolveMediaCoverImage(
        kind: MediaKind.game,
        localPath: findGalgameForActivity(
          _games,
          mediaKey: s.mediaKey,
          title: s.title,
        )?.coverPath,
        decodeWidth: kActivityCoverDecodePixelWidth,
      );
    }
    if (s.isVideo) {
      return resolveMediaCoverImage(
        kind: MediaKind.video,
        localPath: _videoCoverPathByUid[s.mediaKey],
        decodeWidth: kActivityCoverDecodePixelWidth,
      );
    }
    final MediaItem? item = _bookItemsByKey[s.mediaKey];
    return item == null
        ? null
        : resolveMediaCoverImage(
            kind: MediaKind.epub,
            book: item,
            appModel: ref.read(appProvider),
            decodeWidth: kActivityCoverDecodePixelWidth,
          );
  }

  /// 会话行的所属合集名（BUG-2417：会话流混排三域，段 title 是条目名——合集里
  /// 就是分集 / 分册名）。判据与事实行版 [_entryCollection] 同构，输入换成会话；
  /// 会话恒自带身份（段 mediaKey），不需要 legacy 的按 title 反查。
  String? _sessionCollectionName(StudySession s) {
    if (s.mediaKey.isEmpty) return null;
    if (s.isBook) {
      return statCollectionName(
        MediaKind.epub.compositeKey(
          _epubUidByBookKey[s.mediaKey] ?? s.mediaKey,
        ),
        _primaryCollectionByEntry,
        _collectionNamesById,
      );
    }
    return statCollectionName(
      (s.isVideo ? MediaKind.video : MediaKind.game).compositeKey(s.mediaKey),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  /// 删一次会话：段写零 + 游戏骨架行硬删（同一事务），再整页重聚合。
  Future<void> _deleteSession(StudySession s) async {
    await deleteStudySession(ref.read(appProvider).database, s);
    if (mounted) await _load();
  }

  /// 清空**三个域**的全部统计（本 tab 是跨域视图，逐域各清一次 = 三个域 tab 上那
  /// 三颗按钮按一遍的结果，没有第二条清空路径）。确认文案把三域范围与保留项一次
  /// 列全。收藏的词句、制卡历史、游戏库、活动时间线一律保留。
  Future<void> _confirmAndClearAll() async {
    final bool confirmed = await confirmClearAllStatistics(
      context,
      t.stat_clear_all_overview_message,
    );
    if (!confirmed || !mounted) return;
    // 2026-10 体验优化：三个域逐个清空可能要一两秒，期间旧数字还挂在页面上、
    // 按钮还能再点。确认后立即进加载态（动作行按钮随 _loading 一起禁用），
    // 清完重聚合，再给一条完成提示。
    setState(() => _loading = true);
    final FushiDatabase db = ref.read(appProvider).database;
    try {
      await db.clearAllReadingStatistics();
      await db.clearAllVideoStatistics();
      await db.clearAllGalgameStatistics();
    } finally {
      // 清空失败也要重聚合退出加载态（异常照常向上抛，不吞）。
      if (mounted) await _load();
    }
    if (mounted) FushiToast.show(msg: t.stat_cleared_toast);
  }

  /// 改一次会话（日期 / 字数）：走会话编辑的唯一入口（先在 StudyClock 上退役 uid
  /// 再写库），再整页重聚合——改完日期的会话要重新按 gap 归并、重新排序。
  Future<void> _editSession(StudySession s, StudySessionEdit edit) async {
    await applyStudySessionEdit(ref.read(appProvider).database, s, edit);
    if (mounted) await _load();
  }

  /// 清除这一批会话记录（防呆确认已在按钮里做掉）。本 tab 是跨域视图，这一批就是
  /// 三个域的全部会话；只清会话事实，收藏 / 制卡历史 / 查词计数一个都不动。
  Future<void> _clearSessions(List<StudySession> batch) async {
    await deleteStudySessions(ref.read(appProvider).database, batch);
    if (mounted) await _load();
  }

  /// 四张跨域时段卡：主值=学习总时长，副行=学习总字数 + 查词 / 制卡 / 收藏词 /
  /// 收藏句（与阅读、视频两个域 tab 的时段卡逐行同形，只是这里是跨域求和）；
  /// 点卡 → 完整日面的时段明细 sheet。
  Widget _buildSummaryCards(StatWindow w) {
    return buildStatPeriodSummaryGrid(context, <StatPeriodSummary>[
      _periodSummary(
        t.stat_today,
        w.isToday,
        (StatActivityBuckets b) => b.today,
      ),
      _periodSummary(
        t.stat_this_week,
        w.inWeek,
        (StatActivityBuckets b) => b.week,
      ),
      _periodSummary(
        t.stat_this_month,
        w.inMonth,
        (StatActivityBuckets b) => b.month,
      ),
      _periodSummary(
        t.stat_all_time,
        (String _) => true,
        (StatActivityBuckets b) => b.all,
      ),
    ]);
  }

  /// [pick] = 这张卡取分桶里的哪一格（今日 / 本周 / 本月 / 全部），与 [contains]
  /// 的窗口一一对应：四个计数面只分一次桶，四张卡各取一格。
  StatPeriodSummary _periodSummary(
    String label,
    bool Function(String dateKey) contains,
    int Function(StatActivityBuckets) pick,
  ) {
    int chars = 0;
    int ms = 0;
    for (final StatFact f in _daily) {
      if (!contains(f.dateKey)) continue;
      chars += f.chars;
      ms += f.ms;
    }
    // 阅读速度只按阅读域算（[statBookCphOf]）：卡上的时长 / 字数是跨域总和，
    // 视频只计时不计字、游戏 hook 只计字不计时，混进去的「字/时」谁也解释不了。
    final String? cph = statBookCphOf(_daily, contains);
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(value: formatStatChars(chars)),
        StatSummaryLine(
          label: t.stat_reading_speed,
          value: cph ?? kStatEmptyValue,
        ),
        StatSummaryLine(label: t.stat_lookup, value: '${pick(_lookup)}'),
        StatSummaryLine(label: t.stat_mined, value: '${pick(_mined)}'),
        StatSummaryLine(label: t.stat_favorited, value: '${pick(_favorited)}'),
        StatSummaryLine(
          label: t.stat_favorited_sentence,
          value: '${pick(_favoritedSentences)}',
        ),
      ],
    );
  }

  Future<void> _showPeriodDetail(
    String label,
    bool Function(String dateKey) contains,
  ) async {
    final FushiDatabase db = ref.read(appProvider).database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: label,
      contains: contains,
      facts: _daily,
      resolvers: StatPeriodDetailResolvers(
        titleOf: _entryTitle,
        collectionOf: _entryCollection,
        onEntryTap: _openEntry,
        onEntryDelete: (StatPeriodEntryTarget t) =>
            deleteStatPeriodEntry(db, t),
        ambiguousTitlesOf: (String kind) => kind == kActivityMediaBook
            ? _ambiguousBookTitles
            : const <String>{},
      ),
    );
    if (deleted && mounted) await _load();
  }

  /// 事实行 → 展示标题（合集名走 sheet 组头；与首页 dashboard 同判据）。
  String _entryTitle(StatFact f) {
    if (f.isGame) {
      final GalgameEntry? entry = findGalgameForActivity(
        _games,
        mediaKey: f.mediaKey,
        title: f.title,
      );
      final String name = displayTitleForGame(entry: entry, rawTitle: f.title);
      return name.isEmpty ? f.mediaKey : name;
    }
    if (f.isBook) {
      final String? bookKey = f.mediaKey.isNotEmpty
          ? f.mediaKey
          : _bookKeyByTitle[f.title];
      if (bookKey == null) return f.title;
      return ReaderFushiSource.instance.overrideTitleForBookKey(bookKey) ??
          f.title;
    }
    return f.title;
  }

  /// 事实行 → 所属合集名（v83 键契约：epub 经 bookKey→uid 换算）。
  String? _entryCollection(StatFact f) {
    if (f.isBook) {
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
    if (f.mediaKey.isEmpty) return null;
    return statCollectionName(
      (f.isVideo ? MediaKind.video : MediaKind.game).compositeKey(f.mediaKey),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  /// 明细条目 → 打开媒体：视频直达播放、书直达阅读器、游戏进详情页（不静默
  /// 拉起游戏，BUG-1111 同一约定）；查不到的历史条目原地不动。
  Future<void> _openEntry(String mediaKind, String mediaKey) async {
    if (mediaKey.isEmpty || !mounted) return;
    final AppModel appModel = ref.read(appProvider);
    if (mediaKind == kActivityMediaVideo) {
      await openLocalVideoBook(
        context: context,
        repo: VideoBookRepository(appModel.database),
        bookUid: mediaKey,
        playlistCollectionId:
            _primaryCollectionByEntry[MediaKind.video.compositeKey(mediaKey)],
      );
      return;
    }
    if (mediaKind == kActivityMediaGame) {
      for (final GalgameEntry game in _games) {
        if (game.id == mediaKey) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext _) =>
                  GalgameDetailPage(gameId: game.id, initialTab: 0),
            ),
          );
          return;
        }
      }
      return;
    }
    if (mediaKind == kActivityMediaBook) {
      final List<MediaItem> books =
          ref.read(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
          const <MediaItem>[];
      for (final MediaItem item in books) {
        final String? key =
            ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
            ReaderFushiSource.parseSrtBookUid(item.mediaIdentifier);
        if (key == mediaKey) {
          final MediaSource source = item.getMediaSource(appModel: appModel);
          await appModel.openMedia(ref: ref, mediaSource: source, item: item);
          return;
        }
      }
    }
  }
}
