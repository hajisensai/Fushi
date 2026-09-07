import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/video_stat_aggregates.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 视频统计页：与阅读统计（[ReadingStatisticsPage]）位置对等、形态一致，但数据
/// 完全隔离（视频专用表）。展示观看时长 + 完成视频数 + 制卡/收藏计数（不再展示
/// 字幕字数：字数仍在 DB 里采集，只是统计页不再呈现）。
class VideoStatisticsPage extends BasePage {
  const VideoStatisticsPage({super.key, this.embedded = false});

  /// true = 作为统计中心的一个 tab 嵌入（不套 FushiPageScaffold，动作行内联）。
  final bool embedded;

  @override
  BasePageState<VideoStatisticsPage> createState() =>
      _VideoStatisticsPageState();
}

class _VideoStatisticsPageState extends BasePageState<VideoStatisticsPage> {
  bool _loading = true;
  String? _error;

  VideoStatsAggregate _agg = VideoStatsAggregate();
  bool _hasData = false;

  /// **本轮加载时**的统计窗口：聚合（[computeVideoStats]）与时段卡谓词同一个
  /// （BUG-2219）；跨午夜由 [_midnightReload] 整页重聚合。
  StatWindow _window = StatWindow(DateTime.now());
  Timer? _midnightReload;

  /// 观看域日面事实行（loadStatFacts 的 dailyVideos 切片）：时段明细 sheet 的
  /// 数据源（阶段 1——此前这份数据聚合完即丢，时段明细要 per-video × per-day）。
  List<StatFact> _videoFacts = <StatFact>[];

  /// 合集归属映射（书架同源）：按视频 tile 显示所属合集名用。
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'video|<bookUid>' → 折叠归属的主 collectionId。
  /// - [_libraryUidsByTitle]：库表 title→uid 集合（歧义否决与合集名回退共用，
  ///   一套政策：同名多 uid 谁也不许猜）。
  Map<int, String> _collectionNamesById = <int, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<String, Set<String>> _libraryUidsByTitle = <String, Set<String>>{};

  // 制卡 / 收藏计数（来源 'video'），按今日/本周/本月/全部分桶。
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  // 查词计数（来源 'video'）分桶（TODO-1204）。
  StatActivityBuckets _lookup = StatActivityBuckets();

  // 今日每小时观看时长（0-23，毫秒）。
  List<int> _hourlyMs = List.filled(24, 0);

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
    try {
      // 成功路径清错误态（review4-5）：删除/清空直接调本方法（不经 _syncAndLoad
      // 的重置），上一轮失败的 _error 不清会让本轮成功的数据被错误画面挡住。
      _error = null;
      final db = appModelNoUpdate.database;
      // v92：观看事实只走统一事实面（legacy `video_watch_statistics` 日行 +
      // `study_segments` 段，由 loadStatFacts 归一），本页不再直接读表。
      // activityLimit 0：统计页不需要活动流行。
      final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
      final List<StatFact> stats = facts.dailyVideos.toList();
      _videoFacts = stats;
      final List<VideoBookRow> books = await VideoBookRepository(db).listAll();
      final List<DateTime> completed = books
          .map((VideoBookRow b) => b.completedAt)
          .whereType<DateTime>()
          .toList();
      // 合集归属（书架同源）：title→bookUid→'video|bookUid'→合集名，喂 per-video
      // tile。同一份 title→uids 事实同时喂歧义否决与合集名回退（review3-10：两个
      // 消费方一套政策——同名多 uid 的 title 谁也不许猜）。
      _libraryUidsByTitle = <String, Set<String>>{};
      for (final VideoBookRow b in books) {
        _libraryUidsByTitle
            .putIfAbsent(b.title, () => <String>{})
            .add(b.bookUid);
      }
      _collectionNamesById = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
      };
      _primaryCollectionByEntry = await db.getPrimaryCollectionIdByEntry();
      final DateTime now = DateTime.now();
      _window = StatWindow(now);
      _armMidnightReload(now);
      final List<FavoriteWordRow> favs = await db.getFavoriteWordsBySource(
        kStatSourceVideo,
      );
      final List<MiningStatisticRow> mined = await db
          .getMiningStatisticsBySource(kStatSourceVideo);
      // TODO-1204：查词/制卡 per-video 计数（新表）。
      final List<LookupMiningCounterRow> counters = await db
          .getLookupMiningCountersBySource(kStatSourceVideo);
      // v76：观看 / 计数 / 收藏三个行宇宙进同一次身份分组，tile 自带全部数字
      // （吸收判据全局一致，绝不各分各的再拼——那是计数在同名 tile 间游走的根因）。
      // 库表级同名判定（≥2 个 uid 共享一个 title）喂给吸收否决：与迁移回填的
      // 唯一匹配判据同源，行宇宙判据单独用会误吸混合遗留（review-2）。已知限制
      // （review3-6）：歧义不粘——同名视频之一被移出库且没留下任何带身份统计行
      // 后，「曾经同名」这一事实没有任何观察者能复原，遗留行会按 unique-title
      // 判据归并给幸存者；粘化需要新增持久面，成本与收益不成比例，不做。
      _agg = computeVideoStats(
        stats: stats,
        completed: completed,
        now: now,
        counters: counters,
        favorites: favs,
        ambiguousTitles: <String>{
          for (final MapEntry<String, Set<String>> e
              in _libraryUidsByTitle.entries)
            if (e.value.length >= 2) e.key,
        },
      );
      _favorited = bucketActivityByDateKey(
        favs.map((FavoriteWordRow f) => (f.dateKey, 1)),
        now,
      );
      _mined = bucketActivityByDateKey(
        mined.map((MiningStatisticRow m) => (m.dateKey, m.count)),
        now,
      );
      _lookup = bucketActivityByDateKey(
        counters.map((LookupMiningCounterRow c) => (c.dateKey, c.lookupCount)),
        now,
      );
      // 视频来源收藏语句（source==video），旧条目无 dateKey 不参与分桶。
      final List<FavoriteSentence> favSentences =
          await FavoriteSentenceRepository(db).getAll();
      final List<FavoriteSentence> videoFavSentences = favSentences
          .where(
            (FavoriteSentence s) =>
                s.source == kFavoriteSentenceSourceVideo && s.dateKey != null,
          )
          .toList();
      _favoritedSentences = bucketActivityByDateKey(
        videoFavSentences.map((FavoriteSentence s) => (s.dateKey!, 1)),
        now,
      );
      // counters 也算有数据（review4-6）：只在视频域查过词（无观看/收藏/制卡）
      // 时，查词分桶明明有数却显示空状态。
      _hasData =
          stats.isNotEmpty ||
          completed.isNotEmpty ||
          favs.isNotEmpty ||
          mined.isNotEmpty ||
          counters.isNotEmpty ||
          videoFavSentences.isNotEmpty;
      _loadHourlyData(facts);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 今日按小时观看时长：从事实面的小时面取 video 行**累加**。v92 起同一小时
  /// 会同时有 legacy 小时行与多条段，旧实现按行赋值（`=`）会让后来的行覆盖前面
  /// 的，只能用 `+=`。
  void _loadHourlyData(StatFacts facts) {
    final String todayKey = _window.todayKey;
    _hourlyMs = List.filled(24, 0);
    for (final StatFact f in facts.hourly) {
      if (!f.isVideo || f.dateKey != todayKey) continue;
      if (f.hour >= 0 && f.hour < 24) {
        _hourlyMs[f.hour] += f.ms;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> actions = <Widget>[
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
      isEmpty: !_hasData,
      loadingBuilder: () =>
          buildLoading(size: 25, color: theme.colorScheme.primary),
      errorBuilder: (String error) => buildError(error: error),
      emptyMessage: t.video_stat_no_data,
      contentBuilder: _buildContent,
    );
    if (widget.embedded) return buildEmbeddedStatTab(context, actions, body);
    return FushiPageScaffold(
      title: t.video_statistics,
      actions: actions,
      body: body,
    );
  }

  Widget _buildContent() {
    final tokens = FushiDesignTokens.of(context);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(
          child: buildStatHourlyChartSection(context, _hourlyMs),
        ),
        SliverToBoxAdapter(
          child: buildStatDailyDurationChartSection(context, _agg.daily),
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
              t.video_stat_by_video,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildVideoTile(_agg.byVideo[index]),
            childCount: _agg.byVideo.length,
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
        _agg.todayMs,
        _agg.todayCompleted,
        _lookup.today,
        _mined.today,
        _favorited.today,
        _favoritedSentences.today,
        contains: w.isToday,
      ),
      _periodSummary(
        t.stat_this_week,
        _agg.weekMs,
        _agg.weekCompleted,
        _lookup.week,
        _mined.week,
        _favorited.week,
        _favoritedSentences.week,
        contains: w.inWeek,
      ),
      _periodSummary(
        t.stat_this_month,
        _agg.monthMs,
        _agg.monthCompleted,
        _lookup.month,
        _mined.month,
        _favorited.month,
        _favoritedSentences.month,
        contains: w.inMonth,
      ),
      _periodSummary(
        t.stat_all_time,
        _agg.allMs,
        _agg.allCompleted,
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
    int ms,
    int completed,
    int lookup,
    int mined,
    int favorited,
    int favoritedSentences, {
    required bool Function(String dateKey) contains,
  }) {
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        StatSummaryLine(label: t.video_stat_completed, value: '$completed'),
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

  /// 时段卡 → 时段明细 sheet（阶段 1 统一组件；本页是视频统计，明细只吃观看域
  /// 切片 [_videoFacts]）。条目点击直达播放（合集成员带 playlistCollectionId，
  /// 与首页续播同口径）。
  Future<void> _showPeriodDetail(
    String label,
    bool Function(String dateKey) contains,
  ) async {
    // 身份在库集合：明细行可能是已删视频的历史统计，点它不该假装能播。
    final Set<String> libraryUids = <String>{
      for (final Set<String> uids in _libraryUidsByTitle.values) ...uids,
    };
    final FushiDatabase db = appModelNoUpdate.database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: label,
      contains: contains,
      facts: _videoFacts,
      resolvers: StatPeriodDetailResolvers(
        titleOf: (StatFact f) => f.title,
        collectionOf: (StatFact f) => f.mediaKey.isEmpty
            ? null
            : statCollectionName(
                MediaKind.video.compositeKey(f.mediaKey),
                _primaryCollectionByEntry,
                _collectionNamesById,
              ),
        onEntryTap: (String mediaKind, String mediaKey) async {
          if (mediaKey.isEmpty || !libraryUids.contains(mediaKey)) return;
          await openLocalVideoBook(
            context: context,
            repo: VideoBookRepository(db),
            bookUid: mediaKey,
            playlistCollectionId:
                _primaryCollectionByEntry[MediaKind.video.compositeKey(
                  mediaKey,
                )],
          );
        },
        onEntryDelete: (StatPeriodEntryTarget t) =>
            deleteStatPeriodEntry(db, t),
      ),
    );
    // 删过就从 DB 重新聚合：页面上的时段卡 / 排行都得跟着变。
    if (deleted && mounted) await _loadFromDatabase();
  }

  /// 长按 / 右键某个视频那一行 → 确认 → 删除该视频的纯统计并写 video 墓碑防复活，
  /// 再从 DB 重新聚合刷新（TODO-1204 后续）。
  ///
  /// v76：身份感知删除——只删本 tile 展示的行：该 uid 的行 + 本 tile 吸收过的
  /// 同 title 无身份遗留行（[VideoStatBookData.absorbedUnattributed]，与展示层
  /// 是同一次身份分组给出的同一个判据）。同名另一视频的 per-uid 行不再连坐。
  Future<void> _confirmAndDeleteVideo(VideoStatBookData video) async {
    final bool confirmed = await confirmDeleteStatistics(context, video.title);
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.deleteVideoStatisticsForIdentity(
      title: video.title,
      bookUid: video.bookUid,
      includeUnattributed: video.absorbedUnattributed,
    );
    if (!mounted) return;
    await _loadFromDatabase();
  }

  /// TODO-1322：点顶栏「清空统计」→ 危险操作确认 → 清空**全部视频统计**（观看时长 /
  /// 字幕字数 / 时段日志 / 查词 / 制卡计数；不动收藏 / 制卡历史 / 视频），再从 DB 重新聚合刷新。
  Future<void> _confirmAndClearAll() async {
    final bool confirmed = await confirmClearAllStatistics(
      context,
      t.stat_clear_all_video_message,
    );
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.clearAllVideoStatistics();
    if (!mounted) return;
    await _loadFromDatabase();
  }

  /// 按视频 tile 的所属合集名（书架同款「主合集」折叠归属，无则 null）。只认
  /// tile 自带的 bookUid（v76 身份分组）：无身份 tile 存在的意义就是「归属不可
  /// 判」——身份解析拒绝归属的东西，合集名不许再按库表回退猜一个（review4-4：
  /// 行宇宙歧义被否决的 orphan tile，库表恰好只剩一个 uid 时会被贴上那个视频的
  /// 合集名）。
  String? _collectionNameForVideo(VideoStatBookData video) {
    final String? bookUid = video.bookUid;
    if (bookUid == null) return null;
    return statCollectionName(
      MediaKind.video.compositeKey(bookUid),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  Widget _buildVideoTile(VideoStatBookData video) {
    // v76：查词/制卡/收藏数由 computeVideoStats 的同一次身份分组挂在 tile 上，
    // 这里只读——不做任何第二次归并（两套判据 = 计数在同名 tile 间游走）。
    final int favorites = video.favorites;
    final String? collectionName = _collectionNameForVideo(video);
    // 按观看时长排行（byVideo 已按 ms 降序），进度条与排行同维度。
    final maxMs = _agg.byVideo.isEmpty
        ? 1
        : _agg.byVideo.first.ms.clamp(1, 1 << 50);
    final fraction = video.ms / maxMs;
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = FushiDesignTokens.of(context);

    return ContextMenuTrigger(
      // 右键菜单改由绑定表决定唤出键（默认仍是右键）；右键被别的动作占用时自动让位。
      onInvoke: (Offset _) => _confirmAndDeleteVideo(video),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // 移动端长按、桌面端右键都弹删除确认（与阅读统计页同款交互）。
          onLongPress: () => _confirmAndDeleteVideo(video),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.gap / 2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
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
                      formatStatTime(video.ms),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  '${t.stat_lookup}: ${video.lookups} · ${t.stat_mined}: ${video.mines} · ${t.stat_favorited}: $favorites',
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
