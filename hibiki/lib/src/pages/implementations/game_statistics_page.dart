import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/game_stat_aggregates.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/utils.dart';

/// 全游戏统计页。
///
/// 阅读、视频、游戏各自拥有独立统计页；本页的时长与次数只从
/// `galgame_sessions` 事实表 GROUP BY 得出，活动时间线不参与统计。
class GameStatisticsPage extends BasePage {
  const GameStatisticsPage({super.key});

  @override
  BasePageState<GameStatisticsPage> createState() => _GameStatisticsPageState();
}

class _GameStatisticsPageState extends BasePageState<GameStatisticsPage> {
  bool _loading = true;
  String? _error;
  GameStatsAggregate _aggregate = GameStatsAggregate();

  GalgameRepository get _repo => appModelNoUpdate.galgameRepo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<GalgameEntry> games = await _repo.load();
      final Map<String, (int totalSeconds, int sessionCount)> dailyTotals =
          await appModelNoUpdate.database.getAllGalgameDailyTotals();
      _aggregate = computeGameStats(
        games: games,
        dailyTotals: dailyTotals,
        now: DateTime.now(),
      );
    } catch (error, stack) {
      ErrorLogService.instance.log('GameStatisticsPage.load', error, stack);
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return HibikiPageScaffold(
      title: t.game_statistics,
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.refresh,
          tooltip: t.stat_refresh,
          enabled: !_loading,
          onTap: _load,
        ),
        HibikiIconButton(
          icon: Icons.delete_sweep_outlined,
          tooltip: t.stat_clear_all,
          enabled: !_loading,
          onTap: _confirmAndClearAll,
        ),
      ],
      body: buildStatPageBody(
        loading: _loading,
        error: _error,
        isEmpty: _aggregate.allSessions == 0,
        loadingBuilder: () =>
            buildLoading(size: 25, color: theme.colorScheme.primary),
        errorBuilder: (String error) => buildError(error: error),
        emptyMessage: t.game_stat_no_sessions,
        contentBuilder: _buildContent,
      ),
    );
  }

  Widget _buildContent() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(
          child: buildStatDailyDurationChartSection(
            context,
            _aggregate.daily,
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
        SliverPadding(
          padding: EdgeInsets.only(bottom: tokens.spacing.card * 2),
        ),
      ],
    );
  }

  Widget _buildSummaryCards() {
    return buildStatPeriodSummaryGrid(
      context,
      <StatPeriodSummary>[
        _periodSummary(
          t.stat_today,
          _aggregate.todayMs,
          _aggregate.todaySessions,
        ),
        _periodSummary(
          t.stat_this_week,
          _aggregate.weekMs,
          _aggregate.weekSessions,
        ),
        _periodSummary(
          t.stat_this_month,
          _aggregate.monthMs,
          _aggregate.monthSessions,
        ),
        _periodSummary(
          t.stat_all_time,
          _aggregate.allMs,
          _aggregate.allSessions,
        ),
      ],
    );
  }

  StatPeriodSummary _periodSummary(String label, int ms, int sessions) {
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      lines: <StatSummaryLine>[
        StatSummaryLine(
          label: t.game_stat_sessions,
          value: '$sessions',
        ),
      ],
    );
  }

  Widget _buildGameRow(GalgameEntry game) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String lastPlayed = game.lastPlayedMs <= 0
        ? '-'
        : statDateKey(
            DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs),
          );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap / 2,
      ),
      child: HibikiCard(
        onTap: () => _openGame(game),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.sports_esports_outlined,
              color: colors.primary,
            ),
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
            Icon(
              Icons.chevron_right,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGame(GalgameEntry game) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => GalgameDetailPage(
          gameId: game.id,
          initialTab: 0,
        ),
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
