import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/game_statistics_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
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
  Map<String, String> _bookKeyByTitle = <String, String>{};
  Set<String> _ambiguousBookTitles = <String>{};
  Map<String, String> _epubUidByBookKey = <String, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<int, String> _collectionNamesById = <int, String>{};
  List<GalgameEntry> _games = <GalgameEntry>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    try {
      final AppModel appModel = ref.read(appProvider);
      final FushiDatabase db = appModel.database;
      final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
      _daily = facts.daily;
      // BUG-2216：同名 ≥2 本的 title 不进反查表（贴给任意一本都是错贴）。
      _bookKeyByTitle = uniqueBookKeyByTitle(facts.epubRows);
      _ambiguousBookTitles = ambiguousBookTitles(facts.epubRows);
      _epubUidByBookKey = <String, String>{
        for (final EpubBookRow r in facts.epubRows)
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
      padding: EdgeInsets.only(bottom: tokens.spacing.card * 2),
      children: <Widget>[_buildGoalCard(tokens, w), _buildSummaryCards(w)],
    );
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

  /// 四张跨域时段卡：主值=学习总时长，副行=学习总字数；点卡 → 完整日面的时段
  /// 明细 sheet。
  Widget _buildSummaryCards(StatWindow w) {
    return buildStatPeriodSummaryGrid(context, <StatPeriodSummary>[
      _periodSummary(t.stat_today, w.isToday),
      _periodSummary(t.stat_this_week, w.inWeek),
      _periodSummary(t.stat_this_month, w.inMonth),
      _periodSummary(t.stat_all_time, (String _) => true),
    ]);
  }

  StatPeriodSummary _periodSummary(
    String label,
    bool Function(String dateKey) contains,
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
      lines: <StatSummaryLine>[StatSummaryLine(value: formatStatChars(chars))],
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
