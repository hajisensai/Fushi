import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/activity_feed.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 首页仪表盘（阅读向），参考 ReinaManager 首页改造：
///
/// - 区块 1：顶部 4 格统计卡（媒体库 / 总时长 / 今日 / 本周或本月，可 2×2 换行）。
/// - 区块 2：「继续」——把在读的书与在看的视频合并成统一列表，分段切换全部/阅读/观看。
/// - 区块 3：阅读活动热力图（复用 [StatContributionHeatmap]）。
/// - 区块 4：Activity 时间轴——把 [ActivityEventRow] 事件流经纯函数
///   [aggregateActivityEvents] 聚合成「按日期分组」的时间线，顶部按类别筛选。
///
/// 分栏：宽屏（`constraints.maxWidth >= 900`）左列（继续 + 热力图）+ 右列（Activity）；
/// 窄屏堆叠。书与阅读位置走 Riverpod provider（响应式）；视频与统计行在 [initState]
/// 一次性异步载入到本地状态（视频列表天然是 Future）。
class HomeDashboardPage extends ConsumerStatefulWidget {
  const HomeDashboardPage({super.key, required this.videoRepo});

  /// 视频库仓库：仪表盘「继续观看」与视频计数的数据源（[VideoBookRepository.listForShelf]）。
  final VideoBookRepository videoRepo;

  @override
  ConsumerState<HomeDashboardPage> createState() => _HomeDashboardPageState();
}

/// 「继续」统一列表的单条：书与视频归一到同一结构，按 [recentMs] 倒序混排。
/// [book]/[video] 恰有一个非空（由 [isVideo] 区分）。
class _ContinueEntry {
  const _ContinueEntry({
    required this.isVideo,
    required this.title,
    required this.recentMs,
    this.percent = 0,
    this.book,
    this.video,
  });

  final bool isVideo;
  final String title;

  /// 最近活动时刻（epoch 毫秒），仅用于混排排序。
  final int recentMs;

  /// 阅读进度百分比（仅书用，0..100）。
  final int percent;
  final MediaItem? book;
  final VideoBookRow? video;
}

class _HomeDashboardPageState extends ConsumerState<HomeDashboardPage> {
  /// 统计卡右上角「本周/本月」切换：false=本周，true=本月。
  bool _monthRange = false;

  /// 「继续」分段筛选：0=全部，1=阅读，2=观看。
  int _continueFilter = 0;

  /// Activity 分类筛选：null=全部，否则 [kActivityRead]/[kActivityWatch]/
  /// [kActivityGame]/[kActivityAdded]（内存里先过滤 events 再聚合）。
  String? _activityFilter;

  /// [initState] 异步载入的视频库（继续观看 + 视频计数）。
  List<VideoBookRow> _videos = const <VideoBookRow>[];

  /// [initState] 异步载入的活动事件流（时间轴原始数据）。
  List<ActivityEventRow> _activityEvents = const <ActivityEventRow>[];

  /// 每日阅读字数（dateKey → 字数），喂阅读热力图。
  Map<String, int> _readingCharsByDay = const <String, int>{};

  /// 每个视频 bookUid 的最近观看时刻（epoch 毫秒），继续观看排序用。
  Map<String, int> _videoWatchAtByUid = const <String, int>{};

  /// 顶部统计卡的时长窗口聚合（今日/本周/本月/全部，毫秒）。
  DashboardTimeStats _timeStats = const DashboardTimeStats(
    today: 0,
    week: 0,
    month: 0,
    all: 0,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_loadDashboardData());
  }

  /// 一次性异步载入视频库 + 统计行 + 活动事件，并派生热力图/时长窗口/最近观看映射。
  ///
  /// 整段包 try/catch fail-open：任一 DB 读抛异常也不会让整页卡在 loading 或抛未捕获
  /// 异常（各区块对空数据都有降级），并补 [ErrorLogService] 使「首页空」这类问题线上
  /// 可诊断（对照 reader/video 侧统计 flush 的同款 fail-open）。
  Future<void> _loadDashboardData() async {
    try {
      await _loadDashboardDataUnsafe();
    } catch (e, stack) {
      ErrorLogService.instance.log('HomeDashboardPage.load', e, stack);
    }
  }

  Future<void> _loadDashboardDataUnsafe() async {
    final AppModel appModel = ref.read(appProvider);
    final HibikiDatabase db = appModel.database;
    final List<VideoBookRow> videos = await widget.videoRepo.listForShelf();
    final List<ActivityEventRow> events =
        await db.getRecentActivityEvents(limit: 200);
    final List<ReadingStatisticRow> reading =
        await db.getAllReadingStatistics();
    final List<VideoWatchStatisticRow> watch =
        await db.getAllVideoWatchStatistics();
    final DateTime now = DateTime.now();

    // 每日阅读字数聚合（热力图数据源）。
    final Map<String, int> charsByDay = <String, int>{};
    for (final ReadingStatisticRow r in reading) {
      charsByDay[r.dateKey] = (charsByDay[r.dateKey] ?? 0) + r.charactersRead;
    }

    // 时长窗口：阅读时长 + 视频观看时长一起喂进纯函数聚合。
    final DashboardTimeStats stats = sumTimeWindowsByDateKey(
      <(String, int)>[
        for (final ReadingStatisticRow r in reading)
          (r.dateKey, r.readingTimeMs),
        for (final VideoWatchStatisticRow w in watch)
          (w.dateKey, w.watchTimeMs),
      ],
      now,
    );

    // 每个视频的最近观看时刻（按 bookUid 取 lastModified 最大值）。
    final Map<String, int> watchAt = <String, int>{};
    for (final VideoWatchStatisticRow w in watch) {
      if (w.bookUid case final String uid) {
        if (w.lastModified > (watchAt[uid] ?? 0)) {
          watchAt[uid] = w.lastModified;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _videos = videos;
      _activityEvents = events;
      _readingCharsByDay = charsByDay;
      _videoWatchAtByUid = watchAt;
      _timeStats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final AppModel appModel = ref.watch(appProvider);
    final List<MediaItem> books =
        ref.watch(hibikiBooksProvider(appModel.targetLanguage)).valueOrNull ??
            const <MediaItem>[];
    final Map<String, int> lastReadByKey =
        ref.watch(bookLastReadAtProvider).valueOrNull ?? const <String, int>{};
    final DateTime now = DateTime.now();

    final Widget statsCard = _buildStatsSection(tokens, books);
    final Widget continueCard =
        _buildContinueSection(tokens, appModel, books, lastReadByKey);
    final Widget heatmapCard = _buildHeatmapCard(tokens);
    final Widget activityCard = _buildActivitySection(tokens, now);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 900;
        final Widget bodyBelow;
        if (wide) {
          // 两列并排（左：继续+热力图；右：Activity）。整页在纵向滚动的 ListView 里，
          // Row 收到的高度约束是无界（h=Infinity）；左列 Column 必须 mainAxisSize.min
          // 让其高度收敛到内容，否则默认 MainAxisSize.max 会「被迫无限高」而在 layout
          // 阶段抛 BoxConstraints forces an infinite height，导致宽屏首页整块空白。
          bodyBelow = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    continueCard,
                    SizedBox(height: tokens.spacing.card),
                    heatmapCard,
                  ],
                ),
              ),
              SizedBox(width: tokens.spacing.card),
              Expanded(child: activityCard),
            ],
          );
        } else {
          bodyBelow = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              continueCard,
              SizedBox(height: tokens.spacing.card),
              heatmapCard,
              SizedBox(height: tokens.spacing.card),
              activityCard,
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.all(tokens.spacing.card),
          children: <Widget>[
            statsCard,
            SizedBox(height: tokens.spacing.card),
            bodyBelow,
          ],
        );
      },
    );
  }

  // ── 区块 1：顶部统计卡 ───────────────────────────────────────────────────

  /// 顶部 4 格统计卡 + 右上角本周/本月切换。
  Widget _buildStatsSection(HibikiDesignTokens tokens, List<MediaItem> books) {
    final int libraryTotal = books.length + _videos.length;
    final Widget rangeTile = _statTile(
      tokens,
      formatStatTime(_monthRange ? _timeStats.month : _timeStats.week),
      _monthRange ? t.home_stat_this_month : t.home_stat_this_week,
    );
    final List<Widget> tiles = <Widget>[
      _statTile(tokens, '$libraryTotal', t.home_stat_library),
      _statTile(tokens, formatStatTime(_timeStats.all), t.home_stat_total_time),
      _statTile(tokens, formatStatTime(_timeStats.today), t.home_stat_today),
      rangeTile,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: Alignment.centerRight,
          child: _filterChips<bool>(
            tokens: tokens,
            selected: _monthRange,
            onSelected: (bool v) => setState(() => _monthRange = v),
            options: <(bool, String)>[
              (false, t.home_range_week),
              (true, t.home_range_month),
            ],
          ),
        ),
        SizedBox(height: tokens.spacing.gap),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            // 宽度足够 4 格横排，否则 2×2 换行。IntrinsicHeight 收界：整页在纵向
            // ListView 里高度无界，裸 Row(stretch) 会被迫无限高而 layout 崩溃（宽屏
            // 首页整块空白的同款根因）；IntrinsicHeight 让 Row 高度 = 最高格的自然高。
            if (c.maxWidth >= 560) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (int i = 0; i < tiles.length; i++) ...<Widget>[
                      if (i > 0) SizedBox(width: tokens.spacing.gap),
                      Expanded(child: tiles[i]),
                    ],
                  ],
                ),
              );
            }
            return Column(
              children: <Widget>[
                _statRow(tokens, tiles[0], tiles[1]),
                SizedBox(height: tokens.spacing.gap),
                _statRow(tokens, tiles[2], tiles[3]),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 2×2 布局的一行两格。IntrinsicHeight 收界（同 4 格横排：纵向 ListView 下裸
  /// Row(stretch) 会被迫无限高崩溃）。
  Widget _statRow(HibikiDesignTokens tokens, Widget left, Widget right) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: left),
          SizedBox(width: tokens.spacing.gap),
          Expanded(child: right),
        ],
      ),
    );
  }

  /// 单个统计格：大号数值 + 小号标签。
  Widget _statTile(HibikiDesignTokens tokens, String value, String label) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: tokens.surfaces.card,
        shape: const RoundedRectangleBorder(
          borderRadius: HibikiBorderRadius.card,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap + 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle,
            ),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.metadata,
            ),
          ],
        ),
      ),
    );
  }

  // ── 区块 2：继续（书 + 视频统一列表） ─────────────────────────────────────

  /// 「继续」区块：把在读的书（0<position<duration）与在看的视频
  /// （lastPositionMs>0 且未完成）合并、按最近活动时刻倒序，分段筛选后取前 10 条。
  Widget _buildContinueSection(
    HibikiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    Map<String, int> lastReadByKey,
  ) {
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      if (item.position > 0 && item.position < item.duration) {
        final String bookKey =
            ReaderHibikiSource.parseBookKey(item.mediaIdentifier) ??
                item.mediaIdentifier;
        final int recent = lastReadByKey[bookKey] ?? 0;
        final int percent =
            ((item.position / item.duration) * 100).clamp(0, 100).round();
        entries.add(_ContinueEntry(
          isVideo: false,
          title: item.title,
          recentMs: recent,
          percent: percent,
          book: item,
        ));
      }
    }
    for (final VideoBookRow v in _videos) {
      if (v.lastPositionMs > 0 && v.completedAt == null) {
        final int recent = _videoWatchAtByUid[v.bookUid] ??
            v.importedAt?.millisecondsSinceEpoch ??
            0;
        entries.add(_ContinueEntry(
          isVideo: true,
          title: v.title,
          recentMs: recent,
          video: v,
        ));
      }
    }
    entries.sort((_ContinueEntry a, _ContinueEntry b) =>
        b.recentMs.compareTo(a.recentMs));
    final List<_ContinueEntry> filtered = entries
        .where((_ContinueEntry e) {
          switch (_continueFilter) {
            case 1:
              return !e.isVideo;
            case 2:
              return e.isVideo;
            default:
              return true;
          }
        })
        .take(10)
        .toList();

    return _sectionCard(
      tokens,
      title: t.home_continue,
      header: _filterChips<int>(
        tokens: tokens,
        selected: _continueFilter,
        onSelected: (int v) => setState(() => _continueFilter = v),
        options: <(int, String)>[
          (0, t.home_filter_all),
          (1, t.home_filter_read),
          (2, t.home_filter_watch),
        ],
      ),
      child: filtered.isEmpty
          ? Text(t.home_activity_empty, style: tokens.type.metadata)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final _ContinueEntry e in filtered)
                  _buildContinueRow(tokens, appModel, e),
              ],
            ),
    );
  }

  /// 「继续」单条：封面缩略 + 标题 + 副标题（书=「阅读 · x%」/ 视频=「观看」）。
  Widget _buildContinueRow(
    HibikiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry,
  ) {
    final String subtitle = entry.isVideo
        ? t.home_filter_watch
        : '${t.home_filter_read} · ${entry.percent}%';
    return InkWell(
      onTap: () => _openContinueEntry(appModel, entry),
      borderRadius: HibikiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: HibikiBorderRadius.card,
              child: SizedBox(
                width: 48,
                height: 68,
                child: entry.isVideo
                    ? _videoCover(tokens, entry.video!)
                    : FadeInImage(
                        placeholder: MemoryImage(kTransparentImage),
                        image: ReaderHibikiSource.instance
                            .getDisplayThumbnailFromMediaItem(
                          appModel: appModel,
                          item: entry.book!,
                        ),
                        fit: BoxFit.cover,
                        imageErrorBuilder: (_, __, ___) =>
                            _coverPlaceholder(tokens, Icons.menu_book_outlined),
                      ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap + 4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listTitle,
                  ),
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 视频封面：coverPath 存在则 [Image.file]，否则占位图标。
  Widget _videoCover(HibikiDesignTokens tokens, VideoBookRow video) {
    final String? path = video.coverPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholder(tokens, Icons.movie_outlined),
      );
    }
    return _coverPlaceholder(tokens, Icons.movie_outlined);
  }

  /// 封面占位：中性底色 + 图标。
  Widget _coverPlaceholder(HibikiDesignTokens tokens, IconData icon) {
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.surfaces.card),
      child: Center(child: Icon(icon, color: tokens.type.metadata.color)),
    );
  }

  /// 打开「继续」条目：书走 openMedia，视频切到视频 tab。
  Future<void> _openContinueEntry(
    AppModel appModel,
    _ContinueEntry entry,
  ) async {
    if (entry.isVideo) {
      homeShellTabNotifier.value = HomeTab.video;
      return;
    }
    final MediaItem item = entry.book!;
    final MediaSource source = item.getMediaSource(appModel: appModel);
    await appModel.openMedia(ref: ref, mediaSource: source, item: item);
  }

  // ── 区块 3：阅读活动热力图 ───────────────────────────────────────────────

  /// 阅读活动热力图卡（复用 [StatContributionHeatmap]，按每日阅读字数铺格）。
  Widget _buildHeatmapCard(HibikiDesignTokens tokens) {
    return _sectionCard(
      tokens,
      title: t.reading_activity,
      child: StatContributionHeatmap(
        valueByDateKey: _readingCharsByDay,
        now: DateTime.now(),
        baseColor: tokens.surfaces.primary,
        emptyColor: tokens.surfaces.card,
        valueLabel: (String dateKey, int chars) =>
            '${formatStatHeatmapDay(dateKey)} · ${formatStatChars(chars)}',
      ),
    );
  }

  // ── 区块 4：Activity 时间轴 ──────────────────────────────────────────────

  /// Activity 时间轴：顶部分类筛选 → 内存过滤 events → 纯函数聚合 → 按日期分组渲染。
  Widget _buildActivitySection(HibikiDesignTokens tokens, DateTime now) {
    final List<ActivityEventRow> filtered = _activityFilter == null
        ? _activityEvents
        : _activityEvents
            .where((ActivityEventRow e) => e.eventType == _activityFilter)
            .toList();
    final List<ActivityDateGroup> groups = aggregateActivityEvents(filtered);
    final String todayKey = HibikiTimeFormat.dayKey(now);
    final String yesterdayKey =
        HibikiTimeFormat.dayKey(now.subtract(const Duration(days: 1)));

    return _sectionCard(
      tokens,
      title: t.home_activity,
      header: _filterChips<String?>(
        tokens: tokens,
        selected: _activityFilter,
        onSelected: (String? v) => setState(() => _activityFilter = v),
        options: <(String?, String)>[
          (null, t.home_filter_all),
          (kActivityRead, t.home_filter_read),
          (kActivityWatch, t.home_filter_watch),
          (kActivityGame, t.home_filter_game),
          (kActivityAdded, t.home_filter_added),
        ],
      ),
      child: groups.isEmpty
          ? Text(t.home_activity_empty, style: tokens.type.metadata)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final ActivityDateGroup g in groups)
                  _buildActivityGroup(tokens, g, todayKey, yesterdayKey, now),
              ],
            ),
    );
  }

  /// 单个日期分组：日期头 + 该日的条目。
  Widget _buildActivityGroup(
    HibikiDesignTokens tokens,
    ActivityDateGroup group,
    String todayKey,
    String yesterdayKey,
    DateTime now,
  ) {
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
        for (final ActivityEntry e in group.entries)
          _buildActivityEntry(tokens, e, now),
      ],
    );
  }

  /// 单条活动：前置图标 + 标题（粗）+ 副行（动作词 · 相对时间 · [时长] · [session 数]）。
  /// 整行可点：read→书架 tab，视频类→视频 tab（added-book 回书架）。
  Widget _buildActivityEntry(
    HibikiDesignTokens tokens,
    ActivityEntry entry,
    DateTime now,
  ) {
    final List<String> parts = <String>[
      _actionWord(entry.eventType),
      _relativeTimeLabel(entry.latestTimestampMs, now),
      if (entry.totalDurationMs > 0) formatStatTime(entry.totalDurationMs),
      if (entry.sessionCount > 1) t.home_session_count(n: entry.sessionCount),
    ];
    return InkWell(
      onTap: () => _openActivityEntry(entry),
      borderRadius: HibikiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                _activityIcon(entry.eventType),
                size: 20,
                color: tokens.surfaces.primary,
              ),
            ),
            SizedBox(width: tokens.spacing.gap + 4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listTitle,
                  ),
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    parts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点击活动条：read → 书架 tab；added-book → 书架；其余（watch/added-video/game）→ 视频 tab。
  void _openActivityEntry(ActivityEntry entry) {
    if (entry.eventType == kActivityRead || entry.mediaType == 'book') {
      homeShellTabNotifier.value = HomeTab.books;
    } else {
      homeShellTabNotifier.value = HomeTab.video;
    }
  }

  /// 事件类型 → 动作词（i18n）。
  String _actionWord(String eventType) {
    switch (eventType) {
      case kActivityRead:
        return t.home_filter_read;
      case kActivityWatch:
        return t.home_filter_watch;
      case kActivityAdded:
        return t.home_filter_added;
      case kActivityGame:
        return t.home_filter_game;
      default:
        return t.home_filter_all;
    }
  }

  /// 事件类型 → 前置图标。
  IconData _activityIcon(String eventType) {
    switch (eventType) {
      case kActivityRead:
        return Icons.menu_book;
      case kActivityWatch:
        return Icons.movie;
      case kActivityAdded:
        return Icons.add_circle_outline;
      case kActivityGame:
        return Icons.videogame_asset;
      default:
        return Icons.menu_book;
    }
  }

  /// 相对时间结构化结果 → i18n 文案。
  String _relativeTimeLabel(int timestampMs, DateTime now) {
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

  // ── 共享外壳 ────────────────────────────────────────────────────────────

  /// 统一的分区卡：标题（+ 可选右侧 header 控件）+ 内容，套 group 底色圆角。
  Widget _sectionCard(
    HibikiDesignTokens tokens, {
    required String title,
    required Widget child,
    Widget? header,
  }) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: tokens.surfaces.group,
        shape: const RoundedRectangleBorder(
          borderRadius: HibikiBorderRadius.card,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: tokens.type.sectionLabel),
            if (header != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Align(alignment: Alignment.centerLeft, child: header),
            ],
            SizedBox(height: tokens.spacing.gap),
            child,
          ],
        ),
      ),
    );
  }

  /// 泛型筛选 chip 行：[ChoiceChip] 的 [Wrap]（窄屏自动换行，不溢出）。
  Widget _filterChips<T>({
    required HibikiDesignTokens tokens,
    required T selected,
    required ValueChanged<T> onSelected,
    required List<(T value, String label)> options,
  }) {
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (final (T value, String label) in options)
          ChoiceChip(
            label: Text(label),
            selected: selected == value,
            onSelected: (bool isSelected) {
              if (isSelected) onSelected(value);
            },
          ),
      ],
    );
  }
}
