import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/pages/implementations/activity_feed.dart';
import 'package:hibiki/src/pages/implementations/galgame_detail_page.dart';
import 'package:hibiki/src/pages/implementations/game_shared.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart';
import 'package:hibiki/utils.dart';

/// 游戏模块的默认首屏（游戏首页 / 仪表盘），布局对齐 ReinaManager `HomePage`
/// （见 `docs/design/galgame-library-reina-visual-parity.md` §3）。
///
/// 三块内容：
/// - **KPI 条**：总游戏数 / 总时长 / 今日 / 本周（[HibikiDatabase.getGalgameSecondsForDay]
///   跨全部游戏按天聚合；总时长直接取仓储里每个游戏的现算聚合，无额外查询）。
/// - **左列**：最近游玩「Focus 卡」（封面出血背景 + 左→右深色渐变蒙版）+ 随机游戏卡。
/// - **右列**：动态时间线，复用 `activity_events`（game 类）经共享
///   [aggregateActivityEvents] 聚合，与首页 dashboard 同一套读法。
///
/// 数据全部复用既有仓储 / DB 方法，不建投影表、不改 schema。启动 / 详情复用库页的
/// [GalHookSessionController] launch 路径与 [GalgameDetailPage]，不另起炉灶。
class GalgameHomePage extends ConsumerStatefulWidget {
  const GalgameHomePage({
    super.key,
    required this.onShowLibrary,
    required this.onShowMonitor,
    required this.onShowDiagnostics,
    this.sessionController,
    this.onLaunched,
  });

  /// 切到游戏库 / 捕获工作台 / 诊断页（顶部页签复用）。
  final VoidCallback onShowLibrary;
  final VoidCallback onShowMonitor;
  final VoidCallback onShowDiagnostics;

  /// 启动会话控制器（缺省用单例）；启动成功后回调 [onLaunched]（切到工作台）。
  final GalHookSessionController? sessionController;
  final VoidCallback? onLaunched;

  @override
  ConsumerState<GalgameHomePage> createState() => _GalgameHomePageState();
}

/// KPI 条聚合结果（各字段单位见注释）。
class _GameKpis {
  const _GameKpis({
    required this.totalGames,
    required this.totalSeconds,
    required this.todaySeconds,
    required this.weekSeconds,
  });

  final int totalGames;
  final int totalSeconds;
  final int todaySeconds;
  final int weekSeconds;

  static const _GameKpis empty = _GameKpis(
    totalGames: 0,
    totalSeconds: 0,
    todaySeconds: 0,
    weekSeconds: 0,
  );
}

class _GalgameHomePageState extends ConsumerState<GalgameHomePage> {
  late final AppModel _appModel = ref.read(appProvider);
  late final GalgameRepository _repo = _appModel.galgameRepo;
  late final HibikiDatabase _db = _appModel.database;

  /// 当前整库列表（首屏各区块的公共数据源）。
  List<GalgameEntry> _games = const <GalgameEntry>[];

  _GameKpis _kpis = _GameKpis.empty;

  /// 时间线原始事件（游玩事件来自 DB，添加事件由库列表 addedAt 合成）。
  List<ActivityEventRow> _timelineRows = const <ActivityEventRow>[];

  /// 时间线筛选：null=全部 / [kActivityGame]=游玩 / [kActivityAdded]=添加。
  String? _timelineFilter;

  /// 随机游戏卡当前展示的游戏（用户可「换一个」重掷）。
  GalgameEntry? _random;

  /// 启动流程再入守卫（同库页：一次启动含多个 await，避免重复点叠出多开对话框）。
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onRepoChanged);
    _games = _repo.games;
    unawaited(_reload());
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoChanged);
    super.dispose();
  }

  /// 仓储变化（库页增删 / 刮削）→ 重算首屏（不再触发仓储写，避免回环）。
  void _onRepoChanged() {
    if (!mounted) return;
    unawaited(_recompute());
  }

  /// 首次进入：确保仓储已载入一次，再重算。
  Future<void> _reload() async {
    await _repo.load();
    await _recompute();
  }

  /// 重算 KPI / 时间线 / 随机卡（读当前仓储缓存 + 跨天聚合查询，不写仓储）。
  Future<void> _recompute() async {
    final List<GalgameEntry> games = _repo.games;
    final _GameKpis kpis = await _computeKpis(games);
    final List<ActivityEventRow> rows = await _loadTimelineRows(games);
    if (!mounted) return;
    setState(() {
      _games = games;
      _kpis = kpis;
      _timelineRows = rows;
      _random = _pickRandom(games, keep: _random);
    });
  }

  /// KPI 聚合：总数/总时长取仓储现算聚合（零额外查询）；今日/本周跨全部游戏按天
  /// 现查（近 7 天各一条 [HibikiDatabase.getGalgameSecondsForDay]，并发发起）。
  Future<_GameKpis> _computeKpis(List<GalgameEntry> games) async {
    int totalSeconds = 0;
    for (final GalgameEntry g in games) {
      totalSeconds += g.totalPlaySeconds;
    }
    final DateTime now = DateTime.now();
    int today = 0;
    int week = 0;
    final List<Future<void>> futures = <Future<void>>[];
    for (int i = 0; i < 7; i++) {
      final String key =
          HibikiTimeFormat.dayKey(now.subtract(Duration(days: i)));
      // 单线程 Dart 里各 .then 回调不会在 += 语句中途交错，累加安全。
      futures.add(_db.getGalgameSecondsForDay(key).then((int seconds) {
        week += seconds;
        if (i == 0) today = seconds;
      }));
    }
    await Future.wait(futures);
    return _GameKpis(
      totalGames: games.length,
      totalSeconds: totalSeconds,
      todaySeconds: today,
      weekSeconds: week,
    );
  }

  /// 时间线事件：DB 里 game 类活动（游玩 / 已有的添加）+ 由库列表 addedAt 合成的
  /// 「添加」事件（游戏添加当前不落 activity_events，合成后「添加」筛选才有内容）。
  /// 同 (日期, 标题, 类型) 的重复会在 [aggregateActivityEvents] 里并成一条。
  Future<List<ActivityEventRow>> _loadTimelineRows(
    List<GalgameEntry> games,
  ) async {
    final List<ActivityEventRow> dbRows = await _db.getRecentActivityEvents(
      limit: 200,
      eventTypes: <String>[kActivityGame, kActivityAdded],
    );
    final List<ActivityEventRow> gameRows = dbRows
        .where((ActivityEventRow r) => r.mediaType == kActivityMediaGame)
        .toList();
    final List<ActivityEventRow> synthesizedAdds = <ActivityEventRow>[
      for (final GalgameEntry g in games)
        ActivityEventRow(
          id: 0, // 哨兵：合成行不落库，仅供聚合展示。
          eventType: kActivityAdded,
          mediaType: kActivityMediaGame,
          title: g.displayName,
          mediaKey: g.id,
          dateKey: HibikiTimeFormat.dayKey(g.addedAt),
          timestampMs: g.addedAt.millisecondsSinceEpoch,
        ),
    ];
    return <ActivityEventRow>[...gameRows, ...synthesizedAdds];
  }

  /// 最近游玩的游戏（lastPlayedMs 最大且 > 0）；从未游玩返回 null。
  GalgameEntry? get _recentGame {
    GalgameEntry? best;
    for (final GalgameEntry g in _games) {
      if (g.lastPlayedMs <= 0) continue;
      if (best == null || g.lastPlayedMs > best.lastPlayedMs) best = g;
    }
    return best;
  }

  /// 最近玩过的前 4 个游戏（按 lastPlayedMs 倒序）。
  List<GalgameEntry> get _recentlyPlayed {
    final List<GalgameEntry> played = _games
        .where((GalgameEntry g) => g.lastPlayedMs > 0)
        .toList()
      ..sort((GalgameEntry a, GalgameEntry b) =>
          b.lastPlayedMs.compareTo(a.lastPlayedMs));
    return played.take(4).toList();
  }

  /// 随机取一个游戏：优先保留 [keep]（仍在库里就不动，避免每次重算都跳），否则随机。
  GalgameEntry? _pickRandom(List<GalgameEntry> games, {GalgameEntry? keep}) {
    if (games.isEmpty) return null;
    if (keep != null) {
      for (final GalgameEntry g in games) {
        if (g.id == keep.id) return g;
      }
    }
    return games[math.Random().nextInt(games.length)];
  }

  void _reroll() {
    if (_games.isEmpty) return;
    setState(() {
      final GalgameEntry current = _random ?? _games.first;
      GalgameEntry next = current;
      // 库里 >1 个游戏时保证换到不同的一个。
      for (int i = 0;
          i < 8 && next.id == current.id && _games.length > 1;
          i++) {
        next = _games[math.Random().nextInt(_games.length)];
      }
      _random = next;
    });
  }

  /// 启动一个游戏（复用库页 launch 路径：非 Windows 提示不支持；Windows 按位数确保
  /// helper 就位后交给 app 级 Hook 会话）。带再入守卫，失败给可执行处置文案。
  Future<void> _launchGame(GalgameEntry game) async {
    if (_launching) return;
    _launching = true;
    try {
      if (!Platform.isWindows) {
        HibikiToast.show(msg: t.games_launch_unsupported);
        return;
      }
      if (!File(game.exePath).existsSync()) {
        HibikiToast.show(msg: t.games_exe_missing);
        return;
      }
      final bool is32Bit =
          await EngineHookGalAudioSource.exeIs32Bit(game.exePath) ?? false;
      if (GalHookSessionController.defaultInjectorResolver(is32Bit: is32Bit) ==
          null) {
        if (!mounted) return;
        final bool installed = await GalgameHelperInstaller().ensureInjector(
          is32Bit: is32Bit,
          context: context,
        );
        if (!installed || !mounted) return;
      }
      final GalHookSessionController controller =
          widget.sessionController ?? GalHookSessionController.instance;
      final bool launched = await controller.launchGame(game.exePath);
      if (!mounted) return;
      if (!launched) {
        final GalHookSessionState state = controller.state;
        HibikiToast.show(
          msg: galHookFailureLabel(state.injectorFailure) ??
              state.lastError ??
              t.game_capture_launch_failed,
        );
        return;
      }
      widget.onLaunched?.call();
    } finally {
      _launching = false;
    }
  }

  /// 打开详情页；返回后重载（把详情页的编辑 / 刮削同步回首屏）。
  Future<void> _openDetail(GalgameEntry game) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => GalgameDetailPage(
          gameId: game.id,
          onLaunch: () {
            final GalgameEntry? latest = _repo.byId(game.id);
            if (latest != null) unawaited(_launchGame(latest));
          },
        ),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          HibikiPageHeader(
            title: t.nav_game,
            subtitle: t.game_home_subtitle,
            bottom: GameSectionTabs(
              selected: GameSection.dashboard,
              focusIdPrefix: 'game-dashboard-tab',
              onSelectLibrary: widget.onShowLibrary,
              onSelectMonitor: widget.onShowMonitor,
              onSelectDiagnostics: widget.onShowDiagnostics,
            ),
          ),
          Expanded(
            child: _games.isEmpty ? _buildEmpty(context) : _buildBody(context),
          ),
        ],
      ),
    );
  }

  /// 空库态：与库页同款图标 + 提示 + 「添加游戏」入口（切到库页添加）。
  Widget _buildEmpty(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.videogame_asset_outlined,
              size: 64, color: colors.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            t.games_empty,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: widget.onShowLibrary,
            icon: const Icon(Icons.add),
            label: Text(t.games_add),
          ),
        ],
      ),
    );
  }

  /// 有游戏态：KPI 条 + （宽屏）左右两列 /（窄屏）纵向堆叠。
  Widget _buildBody(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 1000;
        final Widget left = _buildLeftColumn(context);
        final Widget timeline = _buildTimeline(context);
        final Widget content = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 6, child: left),
                  SizedBox(width: tokens.spacing.card),
                  Expanded(flex: 5, child: timeline),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  left,
                  SizedBox(height: tokens.spacing.card),
                  timeline,
                ],
              );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.rowVertical,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildKpiStrip(context),
              SizedBox(height: tokens.spacing.card),
              content,
            ],
          ),
        );
      },
    );
  }

  // ── 区域 A：KPI 条 ────────────────────────────────────────────────────────

  Widget _buildKpiStrip(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<Widget> cells = <Widget>[
      _KpiCell(
        icon: Icons.sports_esports_outlined,
        value: '${_kpis.totalGames}',
        label: t.game_kpi_total_games,
      ),
      _KpiCell(
        icon: Icons.timelapse_outlined,
        value: formatStatTime(_kpis.totalSeconds * 1000),
        label: t.game_stat_total_time,
      ),
      _KpiCell(
        icon: Icons.today_outlined,
        value: formatStatTime(_kpis.todaySeconds * 1000),
        label: t.game_stat_today,
      ),
      _KpiCell(
        icon: Icons.date_range_outlined,
        value: formatStatTime(_kpis.weekSeconds * 1000),
        label: t.game_kpi_week,
      ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gap = tokens.spacing.gap + 4;
        // 单行四等分（宽屏）；窄屏降级 2×2。
        if (constraints.maxWidth >= 640) {
          return Row(
            children: <Widget>[
              for (int i = 0; i < cells.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: gap),
                Expanded(child: cells[i]),
              ],
            ],
          );
        }
        return Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: cells[0]),
                SizedBox(width: gap),
                Expanded(child: cells[1]),
              ],
            ),
            SizedBox(height: gap),
            Row(
              children: <Widget>[
                Expanded(child: cells[2]),
                SizedBox(width: gap),
                Expanded(child: cells[3]),
              ],
            ),
          ],
        );
      },
    );
  }

  // ── 左列：Focus 卡 + 随机游戏卡 ──────────────────────────────────────────

  Widget _buildLeftColumn(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final GalgameEntry? recent = _recentGame ?? _random;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (recent != null) _buildFocusCard(context, recent),
        if (recent != null && _random != null)
          SizedBox(height: tokens.spacing.card),
        if (_random != null) _buildRandomSection(context, _random!),
      ],
    );
  }

  /// Focus 卡（最近游玩）：封面出血作背景 + 左→右深色渐变蒙版，内容叠在上面。
  Widget _buildFocusCard(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    final bool hasPlayed = game.lastPlayedMs > 0;
    final String statusLabel = game.playStatus == GalgamePlayStatus.playing
        ? t.games_status_playing
        : (hasPlayed ? t.game_focus_continue : t.game_launch);
    final List<String> subParts = <String>[
      if (hasPlayed)
        '${t.game_stat_last_played}  ${_formatDay(game.lastPlayedMs)}',
      '${t.game_stat_total_time}  ${formatStatTime(game.totalPlaySeconds * 1000)}',
    ];
    final List<GalgameEntry> recent = _recentlyPlayed;

    return ClipRRect(
      borderRadius: HibikiBorderRadius.poster,
      child: Stack(
        children: <Widget>[
          // 封面出血背景。
          Positioned.fill(child: _coverImage(context, game)),
          // 左→右深色渐变蒙版（蒙版内容色，非 surface 语义角色，允许字面深色）。
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    Color(0xF00B1017),
                    Color(0xC00B1017),
                    Color(0x300B1017),
                  ],
                  stops: <double>[0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _StatusPill(label: statusLabel),
                const SizedBox(height: 12),
                Text(
                  game.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subParts.join('   ·   '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: () => unawaited(_launchGame(game)),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(t.game_launch),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_openDetail(game)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      icon: const Icon(Icons.info_outline),
                      label: Text(t.games_view_detail),
                    ),
                  ],
                ),
                if (recent.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  Text(
                    t.game_recently_played,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      for (final GalgameEntry g in recent) ...<Widget>[
                        _RecentThumb(
                          cover: _coverImage(context, g),
                          onTap: () => unawaited(_launchGame(g)),
                          semanticLabel: g.displayName,
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 随机游戏卡（固定约 150 高）：缩略图 + 标题 / 开发商 / 标签 + 换一个 / 启动。
  Widget _buildRandomSection(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final List<String> tags = game.tags.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.game_random_title,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            HibikiActionChip(
              label: t.game_random_reroll,
              icon: Icons.casino_outlined,
              onPressed: _reroll,
            ),
          ],
        ),
        const SizedBox(height: 8),
        HibikiCard(
          padding: const EdgeInsets.all(12),
          focusId: HibikiFocusId('game-dashboard-random-${game.id}'),
          onTap: () => unawaited(_launchGame(game)),
          onSecondaryTap: () => unawaited(_openDetail(game)),
          child: SizedBox(
            height: 126,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: ClipRRect(
                    borderRadius: HibikiBorderRadius.control,
                    child: _coverImage(context, game),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        game.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (game.developer != null &&
                          game.developer!.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          game.developer!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (tags.isNotEmpty)
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            for (final String tag in tags)
                              HibikiTagChip(label: tag),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 右列：动态时间线 ─────────────────────────────────────────────────────

  Widget _buildTimeline(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<ActivityEventRow> filtered = _timelineFilter == null
        ? _timelineRows
        : _timelineRows
            .where((ActivityEventRow r) => r.eventType == _timelineFilter)
            .toList();
    final List<ActivityDateGroup> groups = aggregateActivityEvents(filtered);
    final DateTime now = DateTime.now();
    final String todayKey = HibikiTimeFormat.dayKey(now);
    final String yesterdayKey =
        HibikiTimeFormat.dayKey(now.subtract(const Duration(days: 1)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          t.home_activity,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _timelineChip(null, t.home_filter_all),
            _timelineChip(kActivityGame, t.home_filter_game),
            _timelineChip(kActivityAdded, t.home_filter_added),
          ],
        ),
        SizedBox(height: tokens.spacing.gap),
        if (groups.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.card),
            child: Text(t.home_activity_empty, style: tokens.type.metadata),
          )
        else
          for (final ActivityDateGroup g in groups)
            _buildTimelineGroup(context, g, todayKey, yesterdayKey, now),
      ],
    );
  }

  Widget _timelineChip(String? value, String label) {
    return HibikiSelectableChip(
      label: label,
      selected: _timelineFilter == value,
      onSelected: (_) => setState(() => _timelineFilter = value),
    );
  }

  Widget _buildTimelineGroup(
    BuildContext context,
    ActivityDateGroup group,
    String todayKey,
    String yesterdayKey,
    DateTime now,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String label;
    if (group.dateKey == todayKey) {
      label = t.home_today;
    } else if (group.dateKey == yesterdayKey) {
      label = t.home_yesterday;
    } else {
      label = formatStatHeatmapDay(group.dateKey);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(
            top: tokens.spacing.gap,
            bottom: tokens.spacing.gap / 2,
          ),
          child: Text(label, style: tokens.type.sectionLabel),
        ),
        for (int i = 0; i < group.entries.length; i++)
          _buildTimelineEntry(
            context,
            group.entries[i],
            now,
            isLast: i == group.entries.length - 1,
          ),
      ],
    );
  }

  Widget _buildTimelineEntry(
    BuildContext context,
    ActivityEntry entry,
    DateTime now, {
    required bool isLast,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final GalgameEntry? game = _gameForActivity(entry);
    final List<String> parts = <String>[
      _actionWord(entry.eventType),
      _relativeTime(entry.latestTimestampMs, now),
      if (entry.sessionCount > 1) t.home_session_count(n: entry.sessionCount),
    ];
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 左侧竖轨 + 圆节点。
          Column(
            children: <Widget>[
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: colors.outlineVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // 头像（游戏封面缩略，命中不到回退图标）。
          _TimelineAvatar(
            cover: game == null ? null : _coverImage(context, game),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    parts.join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 活动条 → 对应的库内游戏（先按 mediaKey==id，再按显示名匹配；查不到返回 null）。
  GalgameEntry? _gameForActivity(ActivityEntry entry) {
    final String? key = entry.mediaKey;
    for (final GalgameEntry g in _games) {
      if (key != null && g.id == key) return g;
    }
    for (final GalgameEntry g in _games) {
      if (g.displayName == entry.title) return g;
    }
    return null;
  }

  String _actionWord(String eventType) {
    switch (eventType) {
      case kActivityAdded:
        return t.home_filter_added;
      case kActivityGame:
        return t.home_filter_game;
      default:
        return t.home_filter_all;
    }
  }

  String _relativeTime(int timestampMs, DateTime now) {
    final ActivityRelativeTime rel = activityRelativeTime(timestampMs, now);
    switch (rel.unit) {
      case ActivityRelativeUnit.justNow:
        return t.activity_just_now;
      case ActivityRelativeUnit.minutesAgo:
        return t.activity_minutes_ago(n: rel.value);
      case ActivityRelativeUnit.hoursAgo:
        return t.activity_hours_ago(n: rel.value);
      case ActivityRelativeUnit.daysAgo:
        return t.activity_days_ago(n: rel.value);
    }
  }

  String _formatDay(int epochMs) =>
      HibikiTimeFormat.dayKey(DateTime.fromMillisecondsSinceEpoch(epochMs));

  /// 封面 widget：有 coverPath 且文件存在则显示图片（cover 铺满），否则默认手柄图标
  /// 占位（回落逻辑与库页卡片一致）。
  Widget _coverImage(BuildContext context, GalgameEntry game) {
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _coverFallback(context),
      );
    }
    return _coverFallback(context);
  }

  Widget _coverFallback(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return ColoredBox(
      color: tokens.surfaces.overlay,
      child: Center(
        child: Icon(
          Icons.videogame_asset,
          color: tokens.surfaces.onVariant,
          size: 32,
        ),
      ),
    );
  }
}

/// KPI 单格：图标盒 + 数值（大号粗体）+ 标签（小号次要色）。
class _KpiCell extends StatelessWidget {
  const _KpiCell({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return HibikiCard(
      padding: const EdgeInsets.all(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.12),
                borderRadius: HibikiBorderRadius.control,
              ),
              child: Icon(icon, color: colors.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
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

/// Focus 卡左上角的状态胶囊（叠在深色封面上，主色底 + 白字）。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: HibikiBorderRadius.chip,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Focus 卡底部「最近玩过」缩略图（3:4 小海报，可点启动）。
class _RecentThumb extends StatelessWidget {
  const _RecentThumb({
    required this.cover,
    required this.onTap,
    required this.semanticLabel,
  });

  final Widget cover;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 58,
          child: ClipRRect(
            borderRadius: HibikiBorderRadius.chip,
            child: cover,
          ),
        ),
      ),
    );
  }
}

/// 时间线头像：游戏封面缩略（命中）或类型占位图标。
class _TimelineAvatar extends StatelessWidget {
  const _TimelineAvatar({required this.cover});

  final Widget? cover;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget child = cover ??
        ColoredBox(
          color: tokens.surfaces.overlay,
          child: Icon(
            Icons.videogame_asset,
            size: 18,
            color: tokens.surfaces.onVariant,
          ),
        );
    return SizedBox(
      width: 36,
      height: 36,
      child: ClipRRect(
        borderRadius: HibikiBorderRadius.chip,
        child: child,
      ),
    );
  }
}
