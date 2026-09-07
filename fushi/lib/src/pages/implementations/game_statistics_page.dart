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
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
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

  /// 库内游戏（明细行显示名 + 点击进详情用）。
  List<GalgameEntry> _games = <GalgameEntry>[];

  /// 合集归属（'game|<id>' → 主合集，与书架/统计页同源）。
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<int, String> _collectionNamesById = <int, String>{};

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
      // （legacy hook 字数行 + galgame_sessions 段都在里面归一）。
      final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
      _gameFacts = facts.dailyGames.toList();
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
    final List<Widget> actions = <Widget>[
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
      isEmpty: _aggregate.allSessions == 0,
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
        SliverPadding(
          padding: EdgeInsets.only(bottom: tokens.spacing.card * 2),
        ),
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
      ),
      _periodSummary(
        t.stat_this_week,
        _aggregate.weekMs,
        _aggregate.weekSessions,
        contains: w.inWeek,
      ),
      _periodSummary(
        t.stat_this_month,
        _aggregate.monthMs,
        _aggregate.monthSessions,
        contains: w.inMonth,
      ),
      _periodSummary(
        t.stat_all_time,
        _aggregate.allMs,
        _aggregate.allSessions,
        contains: (String _) => true,
      ),
    ]);
  }

  StatPeriodSummary _periodSummary(
    String label,
    int ms,
    int sessions, {
    required bool Function(String dateKey) contains,
  }) {
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(label: t.game_stat_sessions, value: '$sessions'),
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

  Widget _buildGameRow(GalgameEntry game) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String lastPlayed = game.lastPlayedMs <= 0
        ? '-'
        : statDateKey(DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs));
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap / 2,
      ),
      child: FushiCard(
        onTap: () => _openGame(game),
        child: Row(
          children: <Widget>[
            Icon(Icons.sports_esports_outlined, color: colors.primary),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    game.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    '${t.game_stat_sessions}: ${game.sessionCount} · '
                    '${t.game_stat_last_played}: $lastPlayed',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                formatStatTime(game.totalPlaySeconds * 1000),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            SizedBox(width: tokens.spacing.gap / 2),
            Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
          ],
        ),
      ),
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
