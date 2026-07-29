import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart';
import 'package:hibiki/src/pages/implementations/video_stat_aggregates.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 视频统计页：与阅读统计（[ReadingStatisticsPage]）位置对等、形态一致，但数据
/// 完全隔离（视频专用表）。展示观看时长 + 完成视频数 + 制卡/收藏计数（不再展示
/// 字幕字数：字数仍在 DB 里采集，只是统计页不再呈现）。
class VideoStatisticsPage extends BasePage {
  const VideoStatisticsPage({super.key});

  @override
  BasePageState<VideoStatisticsPage> createState() =>
      _VideoStatisticsPageState();
}

class _VideoStatisticsPageState extends BasePageState<VideoStatisticsPage> {
  bool _loading = true;
  String? _error;

  VideoStatsAggregate _agg = VideoStatsAggregate();
  bool _hasData = false;

  /// 合集归属映射（书架同源）：按视频 tile 显示所属合集名用。
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'video|<bookUid>' → 折叠归属的主 collectionId。
  /// - [_bookUidByTitle]：video_watch_statistics 按 title 聚合，经 video_books 反查 uid。
  Map<int, String> _collectionNamesById = <int, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<String, String> _bookUidByTitle = <String, String>{};

  // 制卡 / 收藏计数（来源 'video'），按今日/本周/本月/全部分桶。
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  // 查词计数（来源 'video'）分桶（TODO-1204）。
  StatActivityBuckets _lookup = StatActivityBuckets();

  // per-video 查词/制卡计数（按 title 聚合，对齐观看时长 tile 的聚合键）。
  Map<String, ({int lookups, int mines})> _videoCounters =
      <String, ({int lookups, int mines})>{};

  // per-video 收藏计数（TODO-1252：按 title 聚合当前收藏活行，无书收藏 title='' 跳过，
  // 只进汇总面板）。收藏取消即删行 → 聚合活行天然回落。
  Map<String, int> _videoFavorites = <String, int>{};

  // 今日每小时观看时长（0-23，毫秒）。
  List<int> _hourlyMs = List.filled(24, 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAndLoad());
  }

  Future<void> _syncAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    try {
      final db = appModelNoUpdate.database;
      final List<VideoWatchStatisticRow> stats =
          await db.getAllVideoWatchStatistics();
      final List<VideoBookRow> books = await VideoBookRepository(db).listAll();
      final List<DateTime> completed = books
          .map((VideoBookRow b) => b.completedAt)
          .whereType<DateTime>()
          .toList();
      // 合集归属（书架同源）：title→bookUid→'video|bookUid'→合集名，喂 per-video tile。
      // bookUid 直接取自已加载的 video_books（无需额外查询）。
      _bookUidByTitle = <String, String>{
        for (final VideoBookRow b in books) b.title: b.bookUid,
      };
      _collectionNamesById = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
      };
      _primaryCollectionByEntry = await db.getPrimaryCollectionIdByEntry();
      final DateTime now = DateTime.now();
      _agg = computeVideoStats(
        stats: stats,
        completed: completed,
        now: now,
      );
      final List<FavoriteWordRow> favs =
          await db.getFavoriteWordsBySource(kStatSourceVideo);
      final List<MiningStatisticRow> mined =
          await db.getMiningStatisticsBySource(kStatSourceVideo);
      _favorited = bucketActivityByDateKey(
        favs.map((FavoriteWordRow f) => (f.dateKey, 1)),
        now,
      );
      _mined = bucketActivityByDateKey(
        mined.map((MiningStatisticRow m) => (m.dateKey, m.count)),
        now,
      );
      // TODO-1204：查词/制卡 per-video 计数（新表）。
      final List<LookupMiningCounterRow> counters =
          await db.getLookupMiningCountersBySource(kStatSourceVideo);
      _lookup = bucketActivityByDateKey(
        counters.map((LookupMiningCounterRow c) => (c.dateKey, c.lookupCount)),
        now,
      );
      _videoCounters = aggregateStatCountersByTitle(counters);
      _videoFavorites = aggregateStatFavoritesByTitle(favs);
      // 视频来源收藏语句（source==video），旧条目无 dateKey 不参与分桶。
      final List<FavoriteSentence> favSentences =
          await FavoriteSentenceRepository(db).getAll();
      final List<FavoriteSentence> videoFavSentences = favSentences
          .where((FavoriteSentence s) =>
              s.source == kFavoriteSentenceSourceVideo && s.dateKey != null)
          .toList();
      _favoritedSentences = bucketActivityByDateKey(
        videoFavSentences.map((FavoriteSentence s) => (s.dateKey!, 1)),
        now,
      );
      _hasData = stats.isNotEmpty ||
          completed.isNotEmpty ||
          favs.isNotEmpty ||
          mined.isNotEmpty ||
          videoFavSentences.isNotEmpty;
      await _loadHourlyData();
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    setState(() => _loading = false);
  }

  Future<void> _loadHourlyData() async {
    final db = appModelNoUpdate.database;
    final todayKey = statTodayKey();
    final rows = await db.getVideoHourlyLogsForDate(todayKey);
    _hourlyMs = List.filled(24, 0);
    for (final row in rows) {
      if (row.hour >= 0 && row.hour < 24) {
        _hourlyMs[row.hour] = row.watchTimeMs;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return HibikiPageScaffold(
      title: t.video_statistics,
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.refresh,
          tooltip: t.stat_refresh,
          enabled: !_loading,
          onTap: _syncAndLoad,
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
        isEmpty: !_hasData,
        loadingBuilder: () =>
            buildLoading(size: 25, color: theme.colorScheme.primary),
        errorBuilder: (String error) => buildError(error: error),
        emptyMessage: t.video_stat_no_data,
        contentBuilder: _buildContent,
      ),
    );
  }

  Widget _buildContent() {
    final tokens = HibikiDesignTokens.of(context);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(
            child: buildStatHourlyChartSection(context, _hourlyMs)),
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
            child: Text(t.video_stat_by_video,
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildVideoTile(_agg.byVideo[index]),
            childCount: _agg.byVideo.length,
          ),
        ),
        SliverPadding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card * 2)),
      ],
    );
  }

  Widget _buildSummaryCards() {
    return buildStatPeriodSummaryGrid(
      context,
      <StatPeriodSummary>[
        _periodSummary(
            t.stat_today,
            _agg.todayMs,
            _agg.todayCompleted,
            _lookup.today,
            _mined.today,
            _favorited.today,
            _favoritedSentences.today),
        _periodSummary(
            t.stat_this_week,
            _agg.weekMs,
            _agg.weekCompleted,
            _lookup.week,
            _mined.week,
            _favorited.week,
            _favoritedSentences.week),
        _periodSummary(
            t.stat_this_month,
            _agg.monthMs,
            _agg.monthCompleted,
            _lookup.month,
            _mined.month,
            _favorited.month,
            _favoritedSentences.month),
        _periodSummary(t.stat_all_time, _agg.allMs, _agg.allCompleted,
            _lookup.all, _mined.all, _favorited.all, _favoritedSentences.all),
      ],
    );
  }

  StatPeriodSummary _periodSummary(
    String label,
    int ms,
    int completed,
    int lookup,
    int mined,
    int favorited,
    int favoritedSentences,
  ) {
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      lines: <StatSummaryLine>[
        StatSummaryLine(
          label: t.video_stat_completed,
          value: '$completed',
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

  /// 长按 / 右键某个视频那一行 → 确认 → 删除该视频的纯统计并写 video 墓碑防复活，
  /// 再从 DB 重新聚合刷新（TODO-1204 后续）。
  Future<void> _confirmAndDeleteVideo(VideoStatBookData video) async {
    final bool confirmed = await confirmDeleteStatistics(context, video.title);
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.deleteVideoStatisticsForTitle(video.title);
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

  /// 按视频 tile 的所属合集名（书架同款「主合集」折叠归属，无则 null）。title→bookUid
  /// 经 video_books 反查（video_watch_statistics 按 title 聚合），拼 'video|<bookUid>'。
  String? _collectionNameForVideo(String title) {
    final String? bookUid = _bookUidByTitle[title];
    if (bookUid == null) return null;
    return statCollectionName(
      MediaKind.video.compositeKey(bookUid),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  Widget _buildVideoTile(VideoStatBookData video) {
    // TODO-1204：查词/制卡计数按 title 聚合（无记录则 0）。
    final ({int lookups, int mines}) counter =
        _videoCounters[video.title] ?? (lookups: 0, mines: 0);
    final int favorites = _videoFavorites[video.title] ?? 0;
    final String? collectionName = _collectionNameForVideo(video.title);
    // 按观看时长排行（byVideo 已按 ms 降序），进度条与排行同维度。
    final maxMs =
        _agg.byVideo.isEmpty ? 1 : _agg.byVideo.first.ms.clamp(1, 1 << 50);
    final fraction = video.ms / maxMs;
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = HibikiDesignTokens.of(context);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // 移动端长按、桌面端右键都弹删除确认（与阅读统计页同款交互）。
        onLongPress: () => _confirmAndDeleteVideo(video),
        onSecondaryTap: () => _confirmAndDeleteVideo(video),
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
                  SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
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
                '${t.stat_lookup}: ${counter.lookups} · ${t.stat_mined}: ${counter.mines} · ${t.stat_favorited}: $favorites',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              SizedBox(height: tokens.spacing.gap / 2),
            ],
          ),
        ),
      ),
    );
  }
}
