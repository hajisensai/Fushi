import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/game_statistics_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 统计中心的四个 tab（阶段 2：三个独立统计页收进一个入口）。
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
  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.stat_center_title,
      body: DefaultTabController(
        length: StatsCenterTab.values.length,
        initialIndex: widget.initialTab.index,
        child: Column(
          children: <Widget>[
            TabBar(
              tabs: <Widget>[
                Tab(text: t.stat_center_tab_overview),
                Tab(text: t.home_filter_read),
                Tab(text: t.home_filter_watch),
                Tab(text: t.home_filter_game),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: const <Widget>[
                  _StatsOverviewTab(),
                  ReadingStatisticsPage(embedded: true),
                  VideoStatisticsPage(embedded: true),
                  GameStatisticsPage(embedded: true),
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
  const _StatsOverviewTab();

  @override
  ConsumerState<_StatsOverviewTab> createState() => _StatsOverviewTabState();
}

class _StatsOverviewTabState extends ConsumerState<_StatsOverviewTab> {
  bool _loading = true;
  String? _error;
  List<StatFact> _daily = <StatFact>[];

  /// 跨域会话流（`StatFacts.sessions`：书 / 视频 / 游戏混排，按结束时刻倒序）。
  List<StudySession> _sessions = <StudySession>[];
  Map<String, String> _bookKeyByTitle = <String, String>{};
  Set<String> _ambiguousBookTitles = <String>{};
  Map<String, String> _epubUidByBookKey = <String, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<int, String> _collectionNamesById = <int, String>{};
  List<GalgameEntry> _games = <GalgameEntry>[];

  /// 跨域计数面分桶（阅读 + 视频 + 游戏三个来源之和）。时段卡之前只有时长 / 字数，
  /// 制卡与查词这两个每天都在动的数字在总览上一个都看不到，只能逐个 tab 翻——
  /// 现在与三个域 tab 的时段卡逐行同形。
  StatActivityBuckets _lookup = StatActivityBuckets();
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    try {
      final AppModel appModel = ref.read(appProvider);
      final FushiDatabase db = appModel.database;
      final StatFacts facts = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
      );
      _daily = facts.daily;
      _sessions = facts.sessions;
      // 跨域 = 不传 source（三个域 tab 各传自己的那一个），所以总览的四个数字
      // 恒等于三个 tab 之和：同一批行、同一个分桶函数，没有第二条口径。
      final DateTime now = DateTime.now();
      final StatCounterFacts counters = facts.counters;
      _lookup = bucketActivityByDateKey(counters.lookupEvents(), now);
      _mined = bucketActivityByDateKey(counters.minedEvents(), now);
      _favorited = bucketActivityByDateKey(counters.favoriteWordEvents(), now);
      _favoritedSentences = bucketActivityByDateKey(
        counters.favoriteSentenceEvents(),
        now,
      );
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
    // 横着切 tab 时按钮在原地变意思。目标入口的理由与 BUG-970 同：目标卡在未设目标
    // 时整卡隐藏（[_buildGoalCard]），没有常驻入口就永远设不了第一个目标。
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
      return Center(
        child: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: tokens.type.metadata));
    }
    final StatWindow w = StatWindow(DateTime.now());
    return ListView(
      // BUG-2440：scaffold 底部安全区不再从 viewport 扣掉，tab 内容末尾自己让开
      // home indicator / 手势条（三个域 tab 走 [buildStatTailSliver]）。
      padding: withBottomSafeInset(
        context,
        EdgeInsets.only(bottom: tokens.spacing.card * 2),
      ),
      children: <Widget>[
        _buildGoalCard(tokens, w),
        _buildSummaryCards(w),
        buildStatDailyDurationChartSection(context, _dailyChartData(w)),
        buildStatSessionSection(
          context,
          sessions: _sessions,
          titleOf: _sessionTitle,
          collectionOf: _sessionCollectionName,
          onDelete: _deleteSession,
          onEdit: _editSession,
          onClearAll: _clearSessions,
        ),
      ],
    );
  }

  /// 目标编辑：与阅读统计 tab 同一份表单、同一个持久化目标。
  Future<void> _editGoals() async {
    final bool saved =
        await showStatGoalEditDialog(context, ref.read(appProvider));
    if (saved && mounted) setState(() {});
  }

  /// 最近 30 天跨域时长柱面：把完整日面 [_daily] 按 dateKey 折成图表点，再按
  /// `lastDayKeys(30)` 补齐空日期——与三个域 tab 的同名图表同一口径（本 tab 之前
  /// 没有这张图，数据其实一直是齐的）。
  List<StatDayData> _dailyChartData(StatWindow w) {
    final Map<String, StatDayData> byKey = <String, StatDayData>{};
    for (final StatFact f in _daily) {
      final StatDayData day = byKey.putIfAbsent(
        f.dateKey,
        () => StatDayData(dateKey: f.dateKey),
      );
      day.chars += f.chars;
      day.ms += f.ms;
    }
    return <StatDayData>[
      for (final String key in w.lastDayKeys(30))
        byKey[key] ?? StatDayData(dateKey: key),
    ];
  }

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
    final FushiDatabase db = ref.read(appProvider).database;
    await db.clearAllReadingStatistics();
    await db.clearAllVideoStatistics();
    await db.clearAllGalgameStatistics();
    if (mounted) await _load();
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

  /// 跨域「今日目标」进度卡（只读展示；编辑入口在首页/阅读统计页）。目标未设
  /// 时整卡隐藏。
  Widget _buildGoalCard(FushiDesignTokens tokens, StatWindow w) {
    final int goal = ref.read(appProvider).readingGoalDailyChars;
    if (goal <= 0) return const SizedBox.shrink();
    final int todayChars = studyGoalCharsForDay(_daily, w.todayKey);
    final double fraction = (todayChars / goal).clamp(0.0, 1.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: FushiCard(
        child: Row(
          children: <Widget>[
            Text(t.stat_goal, style: tokens.type.metadata),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: ClipRRect(
                borderRadius: tokens.radii.chipRadius,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 6,
                  backgroundColor: tokens.surfaces.card,
                  color: tokens.surfaces.primary,
                ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            Text(
              t.stat_goal_progress(read: todayChars, goal: goal),
              style: tokens.type.metadata,
            ),
          ],
        ),
      ),
    );
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
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(value: formatStatChars(chars)),
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
