import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/game_stat_aggregates.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 全游戏统计页。
///
/// 阅读、视频、游戏各自拥有独立统计页；本页的时长与次数只从
/// `galgame_sessions` 事实表 GROUP BY 得出，活动时间线不参与统计。
class GameStatisticsPage extends BasePage {
  const GameStatisticsPage({super.key, this.embedded = false});

  /// true = 作为统计中心的一个 tab 嵌入（不套 FushiPageScaffold，动作行内联）。
  final bool embedded;

  @override
  BasePageState<GameStatisticsPage> createState() => _GameStatisticsPageState();
}

class _GameStatisticsPageState extends BasePageState<GameStatisticsPage> {
  bool _loading = true;
  String? _error;
  GameStatsAggregate _aggregate = GameStatsAggregate();

  /// **本轮加载时**的统计窗口：聚合（[computeGameStats]）与时段卡谓词同一个
  /// （BUG-2219）；跨午夜由 [_midnightReload] 整页重聚合。
  StatWindow _window = StatWindow(DateTime.now());
  Timer? _midnightReload;

  /// 游戏域日面事实行（loadStatFacts 的 dailyGames 切片：galgame_sessions 时长
  /// 段 + legacy hook 字数行）：时段明细 sheet 的数据源（阶段 1——本页此前只按
  /// 天总量聚合，出不了 per-game 明细）。
  List<StatFact> _gameFacts = <StatFact>[];

  /// 游戏域会话流（`StatFacts.sessions` 的游戏切片：galgame_sessions 骨架 + 吸收的
  /// hook 字数段，按结束时刻倒序）。
  List<StudySession> _sessions = <StudySession>[];

  /// 库内游戏（明细行显示名 + 点击进详情用）。
  List<GalgameEntry> _games = <GalgameEntry>[];

  /// 合集归属（'game|<id>' → 主合集，与书架/统计页同源）。
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<int, String> _collectionNamesById = <int, String>{};

  /// 游戏域计数面分桶（查词 / 制卡 / 收藏词 / 收藏句）。本页此前一个都没有——
  /// 不是「忘了显示」：galgame 会话里的查词与制卡以前**全被记成 book 来源**，
  /// 游戏域根本没有这四个数字可取，它们错误地堆在阅读 tab 里。写入面分流补上
  /// `game` 来源之后（`lookup/overlay_stat_source.dart`），这里与阅读 / 观看两个
  /// tab 的时段卡逐行同形，总览的跨域数字恒等于三个 tab 之和。
  ///
  /// 历史数据不回填：旧行的 source_type 已经是 'book' 落库，且不带任何游戏身份，
  /// 没有可靠判据能把它们认回来。所以升级后这四个数字从 0 开始长。
  StatActivityBuckets _lookup = StatActivityBuckets();
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  GalgameRepository get _repo => appModelNoUpdate.galgameRepo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
      if (mounted) unawaited(_load());
    });
  }

  /// 统计中心把三页塞进 TabBarView（无 keepAlive，离屏即 unmount），
  /// 「点开 tab → DB 还在查 → 切走」是一秒可复现的常规操作：首帧 postFrameCallback
  /// 与多次 await 之后的两处 setState 都必须过 mounted 门，否则 debug 断言
  /// `setState() called after dispose()`、release 打在已置空的 _element 上。
  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<GalgameEntry> games = await _repo.load();
      final FushiDatabase db = appModelNoUpdate.database;
      final Map<String, (int totalSeconds, int sessionCount)> dailyTotals =
          await db.getAllGalgameDailyTotals();
      final DateTime now = DateTime.now();
      _window = StatWindow(now);
      _armMidnightReload(now);
      _aggregate = computeGameStats(
        games: games,
        dailyTotals: dailyTotals,
        now: now,
      );
      // 时段明细要 per-game × per-day 事实行：统一事实面是唯一读取入口
      // （legacy hook 字数行 + galgame_sessions 段都在里面归一）。计数面与事实面
      // 同一次加载：总览的跨域数字必须恰好等于三个域 tab 之和，各页各查一遍就会
      // 在口径漂移时静默对不上。
      final StatFacts facts = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
      );
      final StatCounterFacts counterFacts = facts.counters;
      _lookup = bucketActivityByDateKey(
        counterFacts.lookupEvents(source: StatSourceKind.game),
        now,
      );
      _mined = bucketActivityByDateKey(
        counterFacts.minedEvents(source: StatSourceKind.game),
        now,
      );
      _favorited = bucketActivityByDateKey(
        counterFacts.favoriteWordEvents(source: StatSourceKind.game),
        now,
      );
      _favoritedSentences = bucketActivityByDateKey(
        counterFacts.favoriteSentenceEvents(source: StatSourceKind.game),
        now,
      );
      _gameFacts = facts.dailyGames.toList();
      _sessions = facts.sessions.where((StudySession s) => s.isGame).toList();
      _games = games;
      _collectionNamesById = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
      };
      _primaryCollectionByEntry = await db.getPrimaryCollectionIdByEntry();
    } catch (error, stack) {
      ErrorLogService.instance.log('GameStatisticsPage.load', error, stack);
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    // 四个 tab 的动作行逐颗同形（用户 2026-09-10「所有界面都要统一」）：
    // 目标 → 刷新 → 清空全部统计。目标是**跨域的每日学习目标**（同一份表单、同一个
    // 持久化值），本页此前没有入口，切到这个 tab 目标按钮就凭空消失。
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
        onTap: _load,
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
      // counters 也算有数据（与视频页 review4-6 同一个坑）：只在游戏域查过词 /
      // 制过卡而还没玩满一次会话时，四个计数明明有数却显示空状态。
      isEmpty: _aggregate.allSessions == 0 &&
          _lookup.all == 0 &&
          _mined.all == 0 &&
          _favorited.all == 0 &&
          _favoritedSentences.all == 0,
      loadingBuilder: () =>
          buildLoading(size: 25, color: theme.colorScheme.primary),
      errorBuilder: (String error) => buildError(error: error),
      emptyMessage: t.game_stat_no_sessions,
      contentBuilder: _buildContent,
    );
    if (widget.embedded) return buildEmbeddedStatTab(context, actions, body);
    return FushiPageScaffold(
      title: t.game_statistics,
      actions: actions,
      body: body,
    );
  }

  Widget _buildContent() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(
          child: buildStatDailyDurationChartSection(context, _aggregate.daily),
        ),
        SliverToBoxAdapter(
          child: buildStatSessionSection(
            context,
            sessions: _sessions,
            titleOf: _sessionTitle,
            collectionOf: _sessionCollectionName,
            onDelete: _deleteSession,
            onEdit: _editSession,
            onClearAll: _clearSessions,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            child: Text(
              t.game_stat_by_game,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) =>
                _buildGameRow(_aggregate.byGame[index]),
            childCount: _aggregate.byGame.length,
          ),
        ),
        buildStatTailSliver(context),
      ],
    );
  }

  Widget _buildSummaryCards() {
    // 时段谓词与聚合同一个窗口（BUG-2219），跨午夜靠 [_midnightReload] 重聚合。
    final StatWindow w = _window;
    return buildStatPeriodSummaryGrid(context, <StatPeriodSummary>[
      _periodSummary(
        t.stat_today,
        _aggregate.todayMs,
        _aggregate.todaySessions,
        contains: w.isToday,
        pick: (StatActivityBuckets b) => b.today,
      ),
      _periodSummary(
        t.stat_this_week,
        _aggregate.weekMs,
        _aggregate.weekSessions,
        contains: w.inWeek,
        pick: (StatActivityBuckets b) => b.week,
      ),
      _periodSummary(
        t.stat_this_month,
        _aggregate.monthMs,
        _aggregate.monthSessions,
        contains: w.inMonth,
        pick: (StatActivityBuckets b) => b.month,
      ),
      _periodSummary(
        t.stat_all_time,
        _aggregate.allMs,
        _aggregate.allSessions,
        contains: (String _) => true,
        pick: (StatActivityBuckets b) => b.all,
      ),
    ]);
  }

  /// [pick] = 这张卡取分桶里的哪一格（今日 / 本周 / 本月 / 全部），与 [contains]
  /// 的窗口一一对应：四个计数面只分一次桶，四张卡各取一格（与总览 tab 同形）。
  StatPeriodSummary _periodSummary(
    String label,
    int ms,
    int sessions, {
    required bool Function(String dateKey) contains,
    required int Function(StatActivityBuckets) pick,
  }) {
    // 字数（hook 文本）现算：游戏聚合只有时长与次数，字数在事实面 [_gameFacts] 上，
    // 与总览 tab 从 _daily 求和是同一口径。四张同形卡横过去时不能只有游戏少一行。
    int chars = 0;
    for (final StatFact f in _gameFacts) {
      if (contains(f.dateKey)) chars += f.chars;
    }
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(value: formatStatChars(chars)),
        StatSummaryLine(label: t.game_stat_sessions, value: '$sessions'),
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

  /// 时段卡 → 时段明细 sheet（阶段 1 统一组件；本页是游戏统计，明细只吃游戏域
  /// 切片 [_gameFacts]）。条目点击进游戏详情页（不静默拉起游戏，BUG-1111 同一
  /// 约定）；已删游戏点了没有目标页，原地不动。
  Future<void> _showPeriodDetail(
    String label,
    bool Function(String dateKey) contains,
  ) async {
    final FushiDatabase db = appModelNoUpdate.database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: label,
      contains: contains,
      facts: _gameFacts,
      resolvers: StatPeriodDetailResolvers(
        titleOf: (StatFact f) {
          final GalgameEntry? entry = findGalgameForActivity(
            _games,
            mediaKey: f.mediaKey,
            title: f.title,
          );
          final String name = displayTitleForGame(
            entry: entry,
            rawTitle: f.title,
          );
          return name.isEmpty ? f.mediaKey : name;
        },
        collectionOf: (StatFact f) => f.mediaKey.isEmpty
            ? null
            : statCollectionName(
                MediaKind.game.compositeKey(f.mediaKey),
                _primaryCollectionByEntry,
                _collectionNamesById,
              ),
        onEntryTap: (String mediaKind, String mediaKey) async {
          for (final GalgameEntry game in _games) {
            if (game.id == mediaKey) {
              await _openGame(game);
              return;
            }
          }
        },
        onEntryDelete: (StatPeriodEntryTarget t) =>
            deleteStatPeriodEntry(db, t),
      ),
    );
    if (deleted && mounted) await _load();
  }

  /// 「按游戏」一行：三域共用的 [buildStatMediaRow]（本行就是它的原型）。
  Widget _buildGameRow(GalgameEntry game) {
    final String lastPlayed = game.lastPlayedMs <= 0
        ? '-'
        : statDateKey(DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs));
    return buildStatMediaRow(
      context,
      icon: Icons.sports_esports_outlined,
      title: game.displayName,
      meta: '${t.game_stat_sessions}: ${game.sessionCount} · '
          '${t.game_stat_last_played}: $lastPlayed',
      trailing: formatStatTime(game.totalPlaySeconds * 1000),
      onTap: () => unawaited(_openGame(game)),
    );
  }

  Future<void> _openGame(GalgameEntry game) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            GalgameDetailPage(gameId: game.id, initialTab: 0),
      ),
    );
    if (mounted) await _load();
  }

  /// 会话行展示名：库内显示名优先（与时段明细同判据），游戏已删则退回段 title 快照。
  String _sessionTitle(StudySession s) {
    final GalgameEntry? entry = findGalgameForActivity(
      _games,
      mediaKey: s.mediaKey,
      title: s.title,
    );
    return displayTitleForGame(entry: entry, rawTitle: s.title);
  }

  /// 会话行的所属合集名（BUG-2417：同一系列的分作单看名字认不出属于哪套）。
  /// 'game|<galgames.id>' 键契约，与时段明细 sheet 的 collectionOf 同一映射。
  String? _sessionCollectionName(StudySession s) => s.mediaKey.isEmpty
      ? null
      : statCollectionName(
          MediaKind.game.compositeKey(s.mediaKey),
          _primaryCollectionByEntry,
          _collectionNamesById,
        );

  /// 删一次会话：galgame_sessions 骨架行硬删 + 吸收的字数段写零（同一事务），再重聚合。
  Future<void> _deleteSession(StudySession s) async {
    await deleteStudySession(appModelNoUpdate.database, s);
    if (mounted) await _load();
  }

  /// 目标编辑：与阅读 tab、总览 tab 同一份表单、同一个持久化目标（每日学习目标是
  /// **跨域**的一个值，不是每个域各一份）。
  Future<void> _editGoals() async {
    final bool saved = await showStatGoalEditDialog(context, appModelNoUpdate);
    if (saved && mounted) setState(() {});
  }

  /// 改一次会话（日期 / 字数）：走会话编辑的唯一入口（先在 StudyClock 上退役 uid
  /// 再写库），再整页重聚合。游戏会话另有两处特例（骨架行跟着平移；纯时长会话改
  /// 字数会新建一条 chars-only 段），都在 [applyStudySessionEdit] 里。
  Future<void> _editSession(StudySession s, StudySessionEdit edit) async {
    await applyStudySessionEdit(appModelNoUpdate.database, s, edit);
    if (mounted) await _load();
  }

  /// 清除这一批会话记录（防呆确认已在按钮里做掉）：只清会话事实，游戏库、收藏 /
  /// 制卡历史 / 查词计数一个都不动（与逐条删同一边界）。
  Future<void> _clearSessions(List<StudySession> batch) async {
    await deleteStudySessions(appModelNoUpdate.database, batch);
    if (mounted) await _load();
  }

  /// 只清游戏统计事实 `galgame_sessions`。游戏库与 `activity_events` 时间线必须保留。
  Future<void> _confirmAndClearAll() async {
    final bool confirmed = await confirmClearAllStatistics(
      context,
      t.stat_clear_all_game_message,
    );
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.clearAllGalgameStatistics();
    if (!mounted) return;
    await _load();
  }
}
