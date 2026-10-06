import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/mining/gal_hook_failure_text.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/sync/game_stream_mining.dart';
import 'package:fushi/src/sync/game_stream_host.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromePinnedOffset;
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 游戏模块的默认首屏（游戏首页 / 仪表盘），布局对齐 ReinaManager `HomePage`
/// （见 `docs/design/galgame-library-reina-visual-parity.md` §3）。
///
/// 2026-10 M3E 重做后的内容：
/// - **指标卡**：统计中心同款 [StatKpiTile] 四张——总游戏数 / 总时长 / 今日 / 本周
///   （[FushiDatabase.getGalgameSecondsForDay] 跨全部游戏按天聚合；总时长直接取
///   仓储里每个游戏的现算聚合，无额外查询）。
/// - **继续游戏 hero**：饱和 primaryContainer 大卡 + 大封面 + 启动 / 详情主按钮。
/// - **最近玩过**：横滑封面行（焦点站点 `game-recent-<id>`）。
/// - **随机推荐**（「换一个」弹簧切换）+ **动态时间线**：复用 `activity_events`
///   （game 类）经共享 [aggregateActivityEvents] 聚合，与首页 dashboard 同一套读法；
///   按日分组的 M3E 分段列表，日期小标题吸顶。
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
  late final FushiDatabase _db = _appModel.database;

  /// 当前整库列表（首屏各区块的公共数据源）。
  List<GalgameEntry> _games = const <GalgameEntry>[];

  _GameKpis _kpis = _GameKpis.empty;

  /// 首轮重算是否已完成（之前库为空时画骨架而不是空态）。
  bool _loaded = false;

  /// 时间线原始事件（游玩事件来自 DB，添加事件由库列表 addedAt 合成）。
  List<ActivityEventRow> _timelineRows = const <ActivityEventRow>[];

  /// 时间线筛选：null=全部 / [kActivityGame]=游玩 / [kActivityAdded]=添加。
  String? _timelineFilter;

  /// 随机游戏卡当前展示的游戏（用户可「换一个」重掷）。
  GalgameEntry? _random;

  /// 启动流程再入守卫（同库页：一次启动含多个 await，避免重复点叠出多开对话框）。
  bool _launching = false;
  bool _gameStreamBusy = false;
  FushiGameStreamHost? _streamHost;

  bool get _gameStreamStarted => _streamHost?.started ?? false;
  String? get _gameStreamDevice =>
      _streamHost?.session?.clientName ?? _streamHost?.session?.clientId;

  void _onStreamChanged() {
    if (mounted) setState(() {});
  }

  void _onSyncChanged() {
    final FushiGameStreamHost? host =
        _appModel.syncServerController.activeGameStreamHost;
    if (!identical(_streamHost, host)) {
      _streamHost?.removeListener(_onStreamChanged);
      _streamHost = host;
      host?.addListener(_onStreamChanged);
    }
    _onStreamChanged();
  }

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onRepoChanged);
    _games = _repo.games;
    if (Platform.isWindows) {
      _appModel.syncServerController.addListener(_onSyncChanged);
      _onSyncChanged();
    }
    unawaited(_reload());
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoChanged);
    _streamHost?.removeListener(_onStreamChanged);
    if (Platform.isWindows) {
      _appModel.syncServerController.removeListener(_onSyncChanged);
    }
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
      _loaded = true;
    });
  }

  /// KPI 聚合：总数/总时长取仓储现算聚合（零额外查询）；今日/本周跨全部游戏按天
  /// 现查（近 7 天各一条 [FushiDatabase.getGalgameSecondsForDay]，并发发起）。
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
      final String key = FushiTimeFormat.dayKey(
        now.subtract(Duration(days: i)),
      );
      // 单线程 Dart 里各 .then 回调不会在 += 语句中途交错，累加安全。
      futures.add(
        _db.getGalgameSecondsForDay(key).then((int seconds) {
          week += seconds;
          if (i == 0) today = seconds;
        }),
      );
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
  /// 同 (设备, 日期, 类型, 媒体类型, mediaKey——缺失回落标题) 的重复会在
  /// [aggregateActivityEvents] 里并成一条（BUG-1350 后语义）。
  Future<List<ActivityEventRow>> _loadTimelineRows(
    List<GalgameEntry> games,
  ) async {
    // v92：活动流唯一数据源是统一事实面的 [StatFacts.activityRows]（legacy 活动行
    // ∪ hook 字数段 ∪ galgame_sessions 合成的游玩事件）；游玩不再写 activity 行。
    final StatFacts facts = await loadStatFacts(_db);
    final List<ActivityEventRow> gameRows = facts.activityRows
        .where(
          (ActivityEventRow r) =>
              r.mediaType == kActivityMediaGame &&
              (r.eventType == kActivityGame || r.eventType == kActivityAdded),
        )
        .toList();
    final List<ActivityEventRow> synthesizedAdds = <ActivityEventRow>[
      for (final GalgameEntry g in games)
        ActivityEventRow(
          id: 0, // 哨兵：合成行不落库，仅供聚合展示。
          eventType: kActivityAdded,
          mediaType: kActivityMediaGame,
          title: g.displayName,
          mediaKey: g.id,
          dateKey: FushiTimeFormat.dayKey(g.addedAt),
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
    final List<GalgameEntry> played =
        _games.where((GalgameEntry g) => g.lastPlayedMs > 0).toList()
          ..sort(
            (GalgameEntry a, GalgameEntry b) =>
                b.lastPlayedMs.compareTo(a.lastPlayedMs),
          );
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
        FushiToast.show(
          msg: t.game_launch_unsupported,
          severity: ToastSeverity.error,
        );
        return;
      }
      if (!File(game.exePath).existsSync()) {
        FushiToast.show(msg: t.game_exe_missing, severity: ToastSeverity.error);
        return;
      }
      final bool is32Bit =
          await EngineHookGalAudioSource.exeIs32Bit(game.exePath) ?? false;
      // BUG-1448：见 games_library_page 同处注释——「injector 在不在」不是判据，
      // 「版本对不对」才是。这道前置门会让随包新组件永远换不进去。
      if (!mounted) return;
      final bool installed = await GalgameHelperInstaller().ensureInjector(
        is32Bit: is32Bit,
        context: context,
      );
      if (!installed || !mounted) return;
      final GalHookSessionController controller =
          widget.sessionController ?? GalHookSessionController.instance;
      // TODO-2936：应用语言级 / 「游戏」媒体类型的 Profile 绑定（非致命、与启动并行）。
      // 语言取该游戏卡上用户指定的 `galgames.language`（hook 文本无语言声明可读）。
      unawaited(
        ref.read(profileViewModelProvider.notifier).autoApplyBinding(
              languageTag: game.language,
              mediaType: ProfileMediaKind.game,
            ),
      );
      final GalHookLaunchResult result = await controller.launchGame(
        game.exePath,
        launchArguments: game.launchArgumentTokens,
        workdir: game.workdir,
        gameId: game.id,
        gameTitle: game.displayName,
        japaneseLocaleMode: galJapaneseLocaleModeFromKey(
          game.japaneseLocaleMode,
        ),
        // BUG-2047：内容语言是转区 auto 判定的人工真值，entry 本来就在手上。
        contentLanguage: game.language,
      );
      if (!mounted) return;
      // 每种结果都播报（BUG-1089）。旧实现只在 `!launched` 时说话，可注入降级和
      // 「游戏窗口从未出现」这两条路径 `launchGame` 都返回 true，于是点完「启动」
      // 既看不到游戏也看不到任何提示 —— 用户感知就是「点了没反应」。
      final GalHookSessionState state = controller.state;
      final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
        result: result,
        hasBoundWindow: state.boundWindow != null,
        injectorFailure: state.injectorFailure,
      );
      // message 为 null = 本次启动已被更新的操作取代，不该播报（BUG-1142）。
      final String? message = galHookLaunchOutcomeMessage(
        outcome: outcome,
        result: result,
        failure: state.injectorFailure,
        lastError: state.lastError,
        injectorDetail: state.injectorDetail,
      );
      // BUG-1089 的着色面：outcome 已经把「跑起来了 / 只剩整机混音兜底 / 根本没起来」
      // 分好了，toast 的颜色跟着同一份判定走，别再让三种结局长成同一条无色提示。
      if (message != null) {
        FushiToast.show(
          msg: message,
          severity: switch (outcome) {
            GalHookLaunchOutcome.running => ToastSeverity.success,
            GalHookLaunchOutcome.degradedLoopback => ToastSeverity.warning,
            GalHookLaunchOutcome.failed ||
            GalHookLaunchOutcome.windowMissing =>
              ToastSeverity.error,
            // message 为 null 时根本不播报，这里走不到。
            GalHookLaunchOutcome.superseded => ToastSeverity.neutral,
          },
        );
      }
      if (!result.launched) return;
      widget.onLaunched?.call();
    } finally {
      _launching = false;
    }
  }

  Future<void> _toggleGameStream() async {
    if (!Platform.isWindows || _gameStreamBusy) return;
    final FushiSyncServerController sync = _appModel.syncServerController;
    setState(() => _gameStreamBusy = true);
    try {
      if (_gameStreamStarted) {
        await sync.stopGameStream();
        sync.configureGameStreamMining(null);
        return;
      }
      final GalHookSessionState hookState =
          (widget.sessionController ?? GalHookSessionController.instance).state;
      final ExternalWindowInfo? window = hookState.boundWindow;
      if (!hookState.isActive || window == null || window.hwnd == 0) {
        FushiToast.show(
          msg: t.game_stream_hook_required,
          severity: ToastSeverity.warning,
        );
        return;
      }
      final FushiGameStreamMiningAdapter mining = _appModel
          .createGameStreamMiningAdapter();
      sync.configureGameStreamMining(mining);
      final Future<void> starting = sync.startGameStream(hwnd: window.hwnd);
      _onSyncChanged();
      await starting;
      if (mounted) {
        FushiToast.show(
          msg: t.game_stream_waiting,
          severity: ToastSeverity.success,
        );
      }
    } catch (error) {
      if (!_gameStreamStarted) sync.configureGameStreamMining(null);
      if (mounted) {
        FushiToast.show(
          msg: '${t.game_stream_failed}: $error',
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _gameStreamBusy = false);
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
    final Widget content;
    if (_games.isEmpty) {
      // 首次载入还没回来时给骨架，别把「仓储还没读完」画成「空库」。
      // 空态不滚动：让出浮动工具区（MediaQuery 顶部 padding）后再居中。
      content = _loaded
          ? Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: _buildEmpty(context),
            )
          : _buildSkeleton(context);
    } else {
      content = _buildBody(context);
    }
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          FushiPageHeader.customTitle(
            // 在游戏外壳里页签由浮动工具栏画：主位给零尺寸占位，页头整行零高度
            // （动作登记进外壳动作组），不在工具区下面留一条钉死的空白带。
            title: GameSectionTabsHostScope.hostedOf(context)
                ? const SizedBox.shrink()
                : GameSectionTabs(
                    selected: GameSection.dashboard,
                    focusIdPrefix: 'game-dashboard-tab',
                    onSelectLibrary: widget.onShowLibrary,
                    onSelectMonitor: widget.onShowMonitor,
                  ),
            // 统计入口已收敛到首页 dashboard（用户定案 2026-09-01）。
            actions: <Widget>[
              // 主操作：M3E tonal 胶囊按钮，页头把它画在按钮组胶囊旁（不再
              // 被包进组胶囊，见 fushiFloatingHeaderActionGroups）。
              if (Platform.isWindows)
                FushiFilledButton.tonalIcon(
                  onPressed: _gameStreamBusy ? null : _toggleGameStream,
                  icon: FushiIcon(
                    _gameStreamStarted ? FushiIcons.stop : FushiIcons.cast,
                  ),
                  label: Text(
                    _gameStreamBusy
                        ? t.game_stream_busy
                        : _gameStreamStarted
                            ? (_gameStreamDevice == null
                                ? t.game_stream_stop
                                : '${t.game_stream_stop} · ${t.game_stream_connected}: $_gameStreamDevice')
                            : t.game_stream_start,
                  ),
                ),
            ],
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  /// 空库态：与库页同一个共享空态 [FushiPlaceholderMessage]（M3E 饱和色块图标 /
  /// Apple ContentUnavailableView 式无底居中）+「添加游戏」主按钮（切到库页添加）。
  Widget _buildEmpty(BuildContext context) {
    return FushiPlaceholderMessage(
      icon: FushiIcons.games,
      message: t.game_empty,
      action: FushiFilledButton.icon(
        onPressed: widget.onShowLibrary,
        icon: const FushiIcon(FushiIcons.add),
        label: Text(t.game_add),
      ),
    );
  }

  /// 首载骨架：与真实首屏同轮廓（四张指标卡 → 继续游戏大卡 → 最近玩过封面行），
  /// 一层共享闪光扫过整组（有界，[FushiSkeletonShimmer]）。
  Widget _buildSkeleton(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap + 4;
    return FushiSkeletonShimmer(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          // 与正文同一处起点：浮动工具区的让位（MediaQuery 顶部 padding）。
          tokens.spacing.rowVertical + MediaQuery.paddingOf(context).top,
          tokens.spacing.page,
          tokens.spacing.section,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                for (int i = 0; i < 4; i++) ...<Widget>[
                  if (i > 0) SizedBox(width: gap),
                  const Expanded(
                    child: FushiSkeleton(
                      height: 96,
                      borderRadius: FushiM3eShape.cardRadius,
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: tokens.spacing.card),
            const FushiSkeleton(
              height: 232,
              borderRadius: FushiM3eShape.containerLargeRadius,
            ),
            SizedBox(height: tokens.spacing.card),
            FushiSkeleton.line(widthFactor: 0.3, height: 20),
            const SizedBox(height: 12),
            SizedBox(
              height: _kRecentCoverHeight,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  for (int i = 0; i < 8; i++)
                    const Padding(
                      padding: EdgeInsetsDirectional.only(end: 12),
                      child: FushiSkeleton(
                        width: _kRecentTileWidth,
                        height: _kRecentCoverHeight,
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

  /// 有游戏态（2026-10 M3E 重做）：自上而下
  ///
  /// 1. 四张指标卡（统计中心同款 [StatKpiTile]，宽屏一行四张 / 窄屏 2×2）；
  /// 2. 「继续游戏」hero：饱和 primaryContainer 大卡 + 大封面 + M3E 主按钮；
  /// 3. 「最近玩过」横滑封面行；
  /// 4. 随机推荐卡 +（宽屏并排 / 窄屏其后）活动时间线——按日分组的分段列表，
  ///    日期小标题吸顶（每天一个 [SliverMainAxisGroup]，标题只在本组可见时钉住）。
  ///
  /// 整页错峰进场（[FushiEntranceScope]；墨水屏 / 减弱动效下瞬间到位）。
  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 1000;
        final double page = tokens.spacing.page;
        final GalgameEntry? hero = _recentGame ?? _random;
        final List<GalgameEntry> recent = _recentlyPlayed;
        final GalgameEntry? randomGame = _random;
        final Widget? random = randomGame == null
            ? null
            : FushiStaggeredEntrance(
                index: 6,
                child: _buildRandomSection(context, randomGame),
              );
        final List<Widget> timeline = _buildTimelineSlivers(context);
        // 浮动工具区的让位（游戏外壳经 [FushiFloatingChromeScrollInset] 交来的
        // MediaQuery 顶部 padding）由首段内边距吃掉：内容从工具区下方开始、往下
        // 滚时滚到工具区底下，工具区收起后顶部不留空白。吃掉后从子树摘掉，免得
        // 卡片里的竖向列表 / SafeArea 再让一遍。
        final double chromeTop = MediaQuery.paddingOf(context).top;
        return FushiEntranceScope(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: CustomScrollView(
            slivers: <Widget>[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  page,
                  tokens.spacing.rowVertical + chromeTop,
                  page,
                  tokens.spacing.card,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildKpiStrip(context),
                      if (hero != null) ...<Widget>[
                        SizedBox(height: tokens.spacing.card),
                        FushiStaggeredEntrance(
                          index: 4,
                          child: _buildHero(context, hero),
                        ),
                      ],
                      if (recent.isNotEmpty) ...<Widget>[
                        SizedBox(height: tokens.spacing.card),
                        FushiStaggeredEntrance(
                          index: 5,
                          child: _buildRecentRow(context, recent),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (wide)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: page),
                  sliver: SliverCrossAxisGroup(
                    slivers: <Widget>[
                      SliverCrossAxisExpanded(
                        flex: 2,
                        sliver: SliverPadding(
                          padding: EdgeInsetsDirectional.only(
                            end: tokens.spacing.card,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: random ?? const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      SliverCrossAxisExpanded(
                        flex: 3,
                        sliver: SliverMainAxisGroup(slivers: timeline),
                      ),
                    ],
                  ),
                )
              else ...<Widget>[
                if (random != null)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      page,
                      0,
                      page,
                      tokens.spacing.card,
                    ),
                    sliver: SliverToBoxAdapter(child: random),
                  ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: page),
                  sliver: SliverMainAxisGroup(slivers: timeline),
                ),
              ],
              SliverToBoxAdapter(
                child: SizedBox(height: tokens.spacing.section),
              ),
            ],
            ),
          ),
        );
      },
    );
  }

  // ── 区域 A：指标卡 ───────────────────────────────────────────────────────

  Widget _buildKpiStrip(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> cells = <Widget>[
      StatKpiTile(
        icon: FushiIcons.games,
        value: '${_kpis.totalGames}',
        label: t.game_kpi_total_games,
      ),
      StatKpiTile(
        icon: FushiIcons.timer,
        value: formatStatTime(_kpis.totalSeconds * 1000),
        label: t.game_stat_total_time,
      ),
      StatKpiTile(
        icon: FushiIcons.calendar,
        value: formatStatTime(_kpis.todaySeconds * 1000),
        label: t.game_stat_today,
      ),
      StatKpiTile(
        icon: FushiIcons.barChart,
        value: formatStatTime(_kpis.weekSeconds * 1000),
        label: t.game_kpi_week,
      ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gap = tokens.spacing.gap + 4;
        final List<Widget> staggered = <Widget>[
          for (int i = 0; i < cells.length; i++)
            FushiStaggeredEntrance(index: i, child: cells[i]),
        ];
        // 单行四等分（宽屏）；窄屏降级 2×2。
        if (constraints.maxWidth >= 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < cells.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: gap),
                Expanded(child: staggered[i]),
              ],
            ],
          );
        }
        return Column(
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: staggered[0]),
                SizedBox(width: gap),
                Expanded(child: staggered[1]),
              ],
            ),
            SizedBox(height: gap),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: staggered[2]),
                SizedBox(width: gap),
                Expanded(child: staggered[3]),
              ],
            ),
          ],
        );
      },
    );
  }

  // ── 区域 B：继续游戏 hero ────────────────────────────────────────────────

  /// 「继续游戏」大卡（M3E 饱和 primaryContainer 色块；Apple 落到强调色淡染）：
  /// 左侧大封面（无封面 = 饱和色块 + 首字占位），右侧状态胶囊 → 标题 → 元信息
  /// → M3E 主按钮（启动 = filled、详情 = tonal，宽卡用 M 档 56 高）。
  Widget _buildHero(BuildContext context, GalgameEntry game) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final FushiCardColors? toneColors =
        fushiCardToneColors(context, FushiCardTone.primary);
    final Color onTone = toneColors?.onContainer ?? cs.onSurface;
    final bool hasPlayed = game.lastPlayedMs > 0;
    final String statusLabel = game.playStatus == GalgamePlayStatus.playing
        ? t.game_status_playing
        : (hasPlayed ? t.game_focus_continue : t.game_launch);
    final List<String> metaLines = <String>[
      if (hasPlayed)
        '${t.game_stat_last_played}  ${_formatDay(game.lastPlayedMs)}',
      '${t.game_stat_total_time}  ${formatStatTime(game.totalPlaySeconds * 1000)}',
    ];
    final TextStyle heroTitleStyle =
        type.headlineSmallEmphasized.copyWith(color: onTone);
    final TextStyle metaStyle = type.bodyMedium.tabular.copyWith(
      color: onTone.withValues(alpha: 0.78),
    );
    return FushiCard(
      tone: FushiCardTone.primary,
      borderRadius: apple ? null : FushiM3eShape.containerLargeRadius,
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool roomy = constraints.maxWidth >= 560;
          final double coverWidth = roomy ? 168 : 112;
          return Row(
            children: <Widget>[
              SizedBox(
                width: coverWidth,
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: ShelfCoverFrame(child: _GameCoverArt(game: game)),
                ),
              ),
              SizedBox(width: roomy ? 24 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _StatusPill(label: statusLabel),
                    const SizedBox(height: 12),
                    // TODO-2497：两行仍放不下时，桌面悬停显示完整游戏名。
                    ShelfTitleOverflowTooltip(
                      title: game.displayName,
                      style: heroTitleStyle,
                      maxLines: 2,
                      child: Text(
                        game.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: heroTitleStyle,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final String line in metaLines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                    SizedBox(height: roomy ? 20 : 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: <Widget>[
                        FushiFilledButton.icon(
                          onPressed: () => unawaited(_launchGame(game)),
                          size: roomy ? FushiButtonSize.m : null,
                          icon: const FushiIcon(FushiIcons.play),
                          label: Text(t.game_launch),
                        ),
                        FushiFilledButton.tonalIcon(
                          onPressed: () => unawaited(_openDetail(game)),
                          size: roomy ? FushiButtonSize.m : null,
                          icon: const FushiIcon(FushiIcons.info),
                          label: Text(t.game_view_detail),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 区域 C：最近玩过横滑行 ──────────────────────────────────────────────

  /// 横滑封面行：鼠标可左右拖（[HorizontalDragScrollable]）、Shift+滚轮横滚
  /// （Flutter 原生翻轴；裸滚轮留给外层纵滚，BUG-1536），键盘 / 手柄左右键沿焦点
  /// 站点走、焦点自动滚入视口。每张封面按压回弹 + 悬停抬升，点 / Enter 启动。
  Widget _buildRecentRow(BuildContext context, List<GalgameEntry> recent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiSectionTitle(
          t.game_recently_played,
          padding: const EdgeInsets.only(bottom: 8),
        ),
        SizedBox(
          height: _kRecentRowHeight,
          child: SectionSwipeCascade(
            child: HorizontalDragScrollable(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: desktopAwareScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: recent.length,
                separatorBuilder: (BuildContext _, int __) =>
                    const SizedBox(width: 12),
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int i) {
                    final GalgameEntry g = recent[i];
                    return SizedBox(
                      width: _kRecentTileWidth,
                      child: _RecentCoverTile(
                        game: g,
                        onTap: () => unawaited(_launchGame(g)),
                        focusId: FushiFocusId('game-recent-${g.id}'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 区域 D：随机推荐卡 ───────────────────────────────────────────────────

  /// 随机推荐：区块标题 +「换一个」tonal 按钮；换的时候旧卡淡出、新卡从右侧
  /// 弹簧缩放滑入（[AnimatedSwitcher] + context.fushiMotion：位移 / 缩放走
  /// spatial、透明度走 effects）。
  Widget _buildRandomSection(BuildContext context, GalgameEntry game) {
    final FushiMotionScheme motion = context.fushiMotion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 区块标题走共享 [FushiSectionTitle]（MD3 titleLarge / Apple Title 2）。
        FushiSectionTitle(
          t.game_random_title,
          padding: const EdgeInsets.only(bottom: 8),
          trailing: FushiFilledButton.tonalIcon(
            onPressed: _reroll,
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.game_random_reroll),
          ),
        ),
        AnimatedSwitcher(
          duration: motion.spatialDefault.duration,
          reverseDuration: motion.effectsFast.duration,
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previous, if (current != null) current],
          ),
          transitionBuilder: (Widget child, Animation<double> animation) {
            final Animation<double> spatial = CurvedAnimation(
              parent: animation,
              curve: motion.spatialDefault.curve,
            );
            final Animation<double> fade = CurvedAnimation(
              parent: animation,
              curve: motion.effectsDefault.curve,
            );
            return FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.08, 0),
                  end: Offset.zero,
                ).animate(spatial),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1).animate(spatial),
                  child: child,
                ),
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey<String>(game.id),
            child: _buildRandomCard(context, game),
          ),
        ),
      ],
    );
  }

  /// 随机推荐卡本体（M3E secondaryContainer 色块）：封面 + 标题 / 开发商 / 标签；
  /// 点按启动、右键进详情。
  Widget _buildRandomCard(BuildContext context, GalgameEntry game) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiCardColors? toneColors =
        fushiCardToneColors(context, FushiCardTone.secondary);
    final Color onTone = toneColors?.onContainer ?? cs.onSurface;
    final List<String> tags = game.tags.take(3).toList();
    final TextStyle cardTitleStyle =
        type.titleMediumEmphasized.copyWith(color: onTone);
    return FushiCard(
      tone: FushiCardTone.secondary,
      padding: const EdgeInsets.all(12),
      focusId: FushiFocusId('game-dashboard-random-${game.id}'),
      onTap: () => unawaited(_launchGame(game)),
      onSecondaryTap: () => unawaited(_openDetail(game)),
      child: SizedBox(
        height: 144,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 3 / 4,
              child: ShelfCoverFrame(
                child: _GameCoverArt(
                  game: game,
                  decodeWidth: kActivityCoverDecodePixelWidth,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // TODO-2497：两行仍放不下时，桌面悬停显示完整游戏名。
                  ShelfTitleOverflowTooltip(
                    title: game.displayName,
                    style: cardTitleStyle,
                    maxLines: 2,
                    child: Text(
                      game.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: cardTitleStyle,
                    ),
                  ),
                  if (game.developer != null &&
                      game.developer!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      game.developer!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodySmall.copyWith(
                        color: onTone.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (tags.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final String tag in tags) FushiTagChip(label: tag),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 区域 E：活动时间线 ───────────────────────────────────────────────────

  /// 时间线的 sliver 序列：区块标题 + 筛选 chip，然后每天一个
  /// [SliverMainAxisGroup]（吸顶日期小标题 + 当天的 M3E 分段列表）。
  List<Widget> _buildTimelineSlivers(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<ActivityEventRow> filtered = _timelineFilter == null
        ? _timelineRows
        : _timelineRows
            .where((ActivityEventRow r) => r.eventType == _timelineFilter)
            .toList();
    final List<ActivityDateGroup> groups = aggregateActivityEvents(filtered);
    final DateTime now = DateTime.now();
    final String todayKey = FushiTimeFormat.dayKey(now);
    final String yesterdayKey = FushiTimeFormat.dayKey(
      now.subtract(const Duration(days: 1)),
    );

    return <Widget>[
      SliverToBoxAdapter(
        child: FushiStaggeredEntrance(
          index: 7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiSectionTitle(
                t.home_activity,
                padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _timelineChip(null, t.home_filter_all),
                  _timelineChip(kActivityGame, t.home_filter_game),
                  _timelineChip(kActivityAdded, t.home_filter_added),
                ],
              ),
            ],
          ),
        ),
      ),
      if (groups.isEmpty)
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.history,
            message: t.home_activity_empty,
          ),
        )
      else
        for (final ActivityDateGroup g in groups)
          SliverMainAxisGroup(
            key: ValueKey<String>('game-timeline-${g.dateKey}'),
            slivers: <Widget>[
              // 钉住时钉在浮动工具区的可见下沿（随收起动画上移），不被胶囊挡住。
              PinnedHeaderSliver(
                child: FushiFloatingChromePinnedOffset(
                  child: _TimelineDateHeader(
                    label: _timelineDayLabel(g.dateKey, todayKey, yesterdayKey),
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: g.entries.length,
                itemBuilder: (BuildContext context, int i) =>
                    FushiStaggeredEntrance(
                  index: 8 + i,
                  child: _buildTimelineEntry(context, g, i, now),
                ),
              ),
            ],
          ),
    ];
  }

  String _timelineDayLabel(
    String dateKey,
    String todayKey,
    String yesterdayKey,
  ) {
    if (dateKey == todayKey) return t.home_today;
    if (dateKey == yesterdayKey) return t.home_yesterday;
    return formatStatHeatmapDay(dateKey);
  }

  Widget _timelineChip(String? value, String label) {
    return FushiSelectableChip(
      label: label,
      selected: _timelineFilter == value,
      onSelected: (_) => setState(() => _timelineFilter = value),
    );
  }

  /// 时间线一行：M3E 分段行（组首尾大圆角 / 中间小圆角，悬停 / 按下形变；Apple
  /// inset grouped）。行首游戏封面缩略（命中不到回落类型图标），行尾事件类型图标；
  /// 库里还在的游戏可点 / Enter 进详情。
  Widget _buildTimelineEntry(
    BuildContext context,
    ActivityDateGroup group,
    int index,
    DateTime now,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final ActivityEntry entry = group.entries[index];
    final GalgameEntry? game = _gameForActivity(entry);
    final List<String> parts = <String>[
      _actionWord(entry.eventType),
      _relativeTime(entry.latestTimestampMs, now),
      if (entry.sessionCount > 1) t.home_session_count(n: entry.sessionCount),
    ];
    // P4：渲染时应用库内显示名（entry.title 是活动落库时的标题快照，聚合键恒
    // raw；改名后时间轴跟着显示新名，查不到条目回落快照）。game 已按
    // mediaKey/显示名反查。
    final String timelineTitle = displayTitleForGame(
      entry: game,
      rawTitle: entry.title,
    );
    final TextStyle timelineTitleStyle =
        type.bodyLargeEmphasized.copyWith(color: cs.onSurface);
    return FushiGroupedListItem(
      index: index,
      count: group.entries.length,
      separatorIndent: 72,
      focusId: FushiFocusId('game-dashboard-activity-${group.dateKey}-$index'),
      onTap: game == null ? null : () => unawaited(_openDetail(game)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 40,
              height: 40,
              child: game == null
                  ? const FushiListLeadingIcon(
                      FushiIcons.games,
                      shape: FushiLeadingShape.square,
                    )
                  : ClipRRect(
                      borderRadius: FushiM3eShape.smallRadius,
                      child: _GameCoverArt(
                        game: game,
                        decodeWidth: kActivityCoverDecodePixelWidth,
                      ),
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // TODO-2497：两行仍放不下时，桌面悬停显示完整标题。
                  ShelfTitleOverflowTooltip(
                    title: timelineTitle,
                    style: timelineTitleStyle,
                    maxLines: 2,
                    child: Text(
                      timelineTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: timelineTitleStyle,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    parts.join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FushiIcon(
              entry.eventType == kActivityAdded
                  ? FushiIcons.libraryAdd
                  : FushiIcons.play,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 活动条 → 对应的库内游戏。新事件按 id，旧事件兼容 exePath / 标题快照。
  GalgameEntry? _gameForActivity(ActivityEntry entry) => findGalgameForActivity(
        _games,
        mediaKey: entry.mediaKey,
        title: entry.title,
      );

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
      FushiTimeFormat.dayKey(DateTime.fromMillisecondsSinceEpoch(epochMs));
}

/// 「最近玩过」封面行：单张宽度、封面高（3:4）与整行高（封面 + 两行标题 + 上下
/// 留给悬停抬升 / 焦点环的余量）。
const double _kRecentTileWidth = 120;
const double _kRecentCoverHeight = 160;
const double _kRecentRowHeight = 224;

/// 游戏封面：来源解析与首页 Activity / 游戏库共用；没有封面或解码失败时画
/// [_GameCoverPlaceholder]（M3E 饱和色块 + 首字），不再是一块灰。
class _GameCoverArt extends StatelessWidget {
  const _GameCoverArt({
    required this.game,
    this.decodeWidth = kLocalCoverDecodePixelWidth,
  });

  final GalgameEntry game;

  /// 解码宽度：大卡用默认档，缩略图 / 小封面传 [kActivityCoverDecodePixelWidth]。
  final int decodeWidth;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = resolveMediaCoverImage(
      kind: MediaKind.game,
      localPath: game.coverPath,
      decodeWidth: decodeWidth,
    );
    if (provider == null) return _GameCoverPlaceholder(game: game);
    return Image(
      image: provider,
      fit: BoxFit.cover,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          _GameCoverPlaceholder(game: game),
    );
  }
}

/// 无封面占位：按游戏 id 稳定地落在 primary / secondary / tertiary 三种饱和
/// container 色块之一（同一游戏每次同色、相邻游戏多半不同色），中间是游戏名首字；
/// 够大时右下角再压一枚淡手柄图标。Apple 落到强调色淡染（[fushiCardToneColors]），
/// 墨水屏无底色、只留字。
class _GameCoverPlaceholder extends StatelessWidget {
  const _GameCoverPlaceholder({required this.game});

  final GalgameEntry game;

  static const List<FushiCardTone> _tones = <FushiCardTone>[
    FushiCardTone.primary,
    FushiCardTone.secondary,
    FushiCardTone.tertiary,
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    int seed = 0;
    for (final int unit in game.id.codeUnits) {
      seed = (seed * 31 + unit) & 0x3fffffff;
    }
    final FushiCardColors? colors =
        fushiCardToneColors(context, _tones[seed % _tones.length]);
    final Color background = colors?.container ?? cs.surface;
    final Color foreground = colors?.onContainer ?? cs.onSurface;
    final String name = game.displayName.trim();
    final String initial =
        name.isEmpty ? '' : name.characters.first.toUpperCase();
    return ColoredBox(
      color: background,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool showBadge = initial.isNotEmpty &&
              constraints.maxWidth.isFinite &&
              constraints.maxWidth >= 72;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.56,
                  heightFactor: 0.42,
                  child: FittedBox(
                    child: initial.isEmpty
                        ? FushiIcon(FushiIcons.games, color: foreground)
                        : Text(
                            initial,
                            style: context.fushiType.displayMediumEmphasized
                                .copyWith(color: foreground),
                          ),
                  ),
                ),
              ),
              if (showBadge)
                PositionedDirectional(
                  end: 8,
                  bottom: 8,
                  child: FushiIcon(
                    FushiIcons.games,
                    size: 16,
                    color: foreground.withValues(alpha: 0.6),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// hero 左上角的状态胶囊：M3E 在 primaryContainer 上压一枚 primary 实心胶囊；
/// Apple 强调色胶囊 + 白字；墨水屏描边无底。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color background = eink
        ? Colors.transparent
        : apple
            ? appleColorsOf(context).accent
            : cs.primary;
    final Color foreground = eink
        ? cs.onSurface
        : apple
            ? Colors.white
            : cs.onPrimary;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: StadiumBorder(
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Text(
          label,
          style: context.fushiType.labelLargeEmphasized.copyWith(
            color: foreground,
          ),
        ),
      ),
    );
  }
}

/// 「最近玩过」横滑行的一张封面：3:4 封面框 + 两行标题；按压回弹
/// （[FushiPressScale]）+ 悬停抬升（[FushiHoverLift]，封面框跟着抬投影）。
class _RecentCoverTile extends StatelessWidget {
  const _RecentCoverTile({
    required this.game,
    required this.onTap,
    required this.focusId,
  });

  final GalgameEntry game;
  final VoidCallback onTap;

  /// 焦点站点 id（`game-recent-<gameId>`）：手柄/键盘可聚焦，Enter/A 启动。
  final FushiFocusId focusId;

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle = context.fushiType.labelLarge.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
    );
    final Widget tile = Semantics(
      label: game.displayName,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: FushiPressScale(
          child: FushiHoverLift(
            builder: (BuildContext context, bool _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: ShelfCoverFrame(
                    child: _GameCoverArt(
                      game: game,
                      decodeWidth: kActivityCoverDecodePixelWidth,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ShelfTitleOverflowTooltip(
                    title: game.displayName,
                    style: titleStyle,
                    maxLines: 2,
                    child: Text(
                      game.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 焦点接线：与 GalgamePosterCard 同款——存在焦点根时注册焦点站点（焦点描边由
    // 全局 FushiFocusRing 绘制），并把 ActivateIntent（Enter / 手柄 A）接到 onTap；
    // Actions 必须在 FushiFocusTarget 之上（手柄 A 从焦点节点向上找 handler）。
    // 无焦点根（纯 widget-test）直接返回原样。
    if (FushiFocusRoot.maybeControllerOf(context) == null) {
      return tile;
    }
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(id: focusId, child: tile),
    );
  }
}

/// 时间线吸顶日期小标题：页面底色条（内容从它下面滚过去）上压一枚
/// secondaryContainer 胶囊（M3E）；Apple 是分组小标题文字；墨水屏描边胶囊。
class _TimelineDateHeader extends StatelessWidget {
  const _TimelineDateHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Widget text = apple
        ? Text(label, style: tokens.type.sectionLabel)
        : DecoratedBox(
            decoration: ShapeDecoration(
              color: eink ? Colors.transparent : cs.secondaryContainer,
              shape: StadiumBorder(
                side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                label,
                style: context.fushiType.labelLargeEmphasized.copyWith(
                  color: eink ? cs.onSurface : cs.onSecondaryContainer,
                ),
              ),
            ),
          );
    final Widget row = Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap),
      child: Align(alignment: AlignmentDirectional.centerStart, child: text),
    );
    // M3E：吸顶的是一枚自带填色的胶囊，浮在内容上（内容从它两侧滚过），不再垫
    // 一条整宽页面底色条——吸到视口顶时那条实色带就是工具区收起后顶部的一块
    // 硬边，顶部可读性归外壳浮动工具区的共享遮罩。Apple（纯文字小标题）与墨水
    // 屏（透明描边胶囊）没有自己的填色，仍垫底色免得文字压在内容上。
    if (!apple && !eink) return row;
    return ColoredBox(color: tokens.surfaces.page, child: row);
  }
}
