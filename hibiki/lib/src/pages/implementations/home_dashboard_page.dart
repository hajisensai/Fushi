import 'dart:async';
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
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_cover_image.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';
import 'package:hibiki/src/utils/misc/dashboard_remote_merge.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 首页仪表盘（阅读向），参考 ReinaManager 首页改造：
///
/// - 区块 1：学习活动热力图（复用 [StatContributionHeatmap]），置顶。
/// - 区块 2：「继续」——把在读的书与在看的视频合并成统一列表，分段切换全部/阅读/观看。
/// - 区块 3：Activity 时间轴——把 [ActivityEventRow] 事件流经纯函数
///   [aggregateActivityEvents] 聚合成「按日期分组」的时间线，顶部按类别筛选。
///
/// 分栏：宽屏（`constraints.maxWidth >= 900`）热力图置顶通栏 + 下方左列（继续）右列
/// （Activity）；窄屏堆叠。书与阅读位置走 Riverpod provider（响应式）；视频与活动事件在
/// [initState] 一次性异步载入到本地状态（视频列表天然是 Future）。
class HomeDashboardPage extends ConsumerStatefulWidget {
  const HomeDashboardPage({super.key, required this.videoRepo});

  /// 视频库仓库：仪表盘「继续观看」与视频计数的数据源（[VideoBookRepository.listForShelf]）。
  final VideoBookRepository videoRepo;

  @override
  ConsumerState<HomeDashboardPage> createState() => _HomeDashboardPageState();
}

/// 「继续」统一列表的单条：书与视频归一到同一结构，按 [recentMs] 倒序混排。
/// [book]/[video]/[remote] 恰有一个非空（本地书 / 本地视频 / 互联 host 条目）。
class _ContinueEntry {
  const _ContinueEntry({
    required this.isVideo,
    required this.title,
    required this.recentMs,
    this.percent = 0,
    this.book,
    this.video,
    this.remote,
  });

  final bool isVideo;
  final String title;

  /// 最近活动时刻（epoch 毫秒），仅用于混排排序。
  final int recentMs;

  /// 阅读进度百分比（仅书用，0..100）。
  final int percent;
  final MediaItem? book;
  final VideoBookRow? video;

  /// 互联 host 上的在读书/在看视频（本地无此条目时的远端补位，「继续也走互联」）。
  final RemoteContinueCandidate? remote;
}

class _HomeDashboardPageState extends ConsumerState<HomeDashboardPage> {
  /// 「继续」分段筛选：0=全部，1=阅读，2=观看。
  int _continueFilter = 0;

  /// Activity 分类筛选：null=全部，否则 [kActivityRead]/[kActivityWatch]/
  /// [kActivityGame]/[kActivityAdded]（内存里先过滤 events 再聚合）。
  String? _activityFilter;

  /// [initState] 异步载入的视频库（继续观看 + 视频计数）。
  List<VideoBookRow> _videos = const <VideoBookRow>[];

  /// [initState] 异步载入的活动事件流（时间轴原始数据，本地 + 远端混排后）。
  List<ActivityEventRow> _activityEvents = const <ActivityEventRow>[];

  /// 本地活动事件（远端到达后与之重混排的基底）。
  List<ActivityEventRow> _localActivityEvents = const <ActivityEventRow>[];

  /// 互联 host 上的「继续」远端补位候选（本地无同 key/uid 的在读书/在看视频）。
  List<RemoteContinueCandidate> _remoteContinue =
      const <RemoteContinueCandidate>[];

  /// 远端封面取图器（互联 client 可用时非空；喂 [RemoteCoverImage]）。
  RemoteCoverFetcher? _remoteCoverFetcher;

  /// 互联 host 设备显示名（配对时存进 [HibikiClientUrl.deviceName]；取不到时
  /// 渲染层回退通用「远端」文案）。「标明设备来源」的数据源。
  String? _remoteDeviceName;

  /// 远端活动事件行的 identity 集（这些行 id=0 哨兵且可能与本地行值相等，必须按
  /// 实例识别），供聚合按设备分组 + 打设备标签。
  Set<ActivityEventRow> _remoteActivityRows = Set<ActivityEventRow>.identity();

  /// 每日阅读字数（dateKey → 字数），喂阅读热力图。
  Map<String, int> _readingCharsByDay = const <String, int>{};

  /// 每日学习时长（dateKey → 毫秒，阅读 + 视频观看），热力图气泡的第二维度
  /// （用户反馈「点击只显示字数」——字数和时长本就都按日落库，一起外显）。
  Map<String, int> _readingTimeMsByDay = const <String, int>{};

  /// 每个视频 bookUid 的最近观看时刻（epoch 毫秒），继续观看排序用。
  Map<String, int> _videoWatchAtByUid = const <String, int>{};

  /// 订阅「数据变了」信号（阅读/观看/导入落库）以自动刷新，及其防抖定时器。
  /// 首页不保活、且阅读器是 pushed 路由（读完回来首页不重建 initState），故必须靠
  /// DB 表级变更主动重查，否则「打开一本书读完回来」活动/热力图仍是旧数据。
  StreamSubscription<void>? _dataChangeSub;
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDashboardData());
    // 阅读/观看/导入写库 → 表级变更 → 防抖后重查聚合，首页自动刷新（竞态无关：
    // 信号在写入 commit 后才发，重查读到的是已落库数据）。
    _dataChangeSub = ref
        .read(appProvider)
        .database
        .watchDashboardDataChanges()
        .listen((_) => _scheduleReload());
  }

  /// 表变更后防抖重载（多次连续写只重查一次，避免频繁 setState）。
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(_loadDashboardData());
    });
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    unawaited(_dataChangeSub?.cancel());
    super.dispose();
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

    // 每日「读到的字数」聚合（活动热力图数据源）：书内阅读字数 + 视频字幕字数
    // 一起计入——看带字幕的视频也是在读字，故热力图同时反映阅读与观看活动，不再
    // 只有书籍点亮（用户反馈「阅读活动只有书籍，其他的呢」）。
    final Map<String, int> charsByDay = <String, int>{};
    final Map<String, int> timeMsByDay = <String, int>{};
    for (final ReadingStatisticRow r in reading) {
      charsByDay[r.dateKey] = (charsByDay[r.dateKey] ?? 0) + r.charactersRead;
      timeMsByDay[r.dateKey] = (timeMsByDay[r.dateKey] ?? 0) + r.readingTimeMs;
    }
    for (final VideoWatchStatisticRow w in watch) {
      charsByDay[w.dateKey] = (charsByDay[w.dateKey] ?? 0) + w.subtitleChars;
      timeMsByDay[w.dateKey] = (timeMsByDay[w.dateKey] ?? 0) + w.watchTimeMs;
    }

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
      _localActivityEvents = events;
      _activityEvents = events;
      _readingCharsByDay = charsByDay;
      _readingTimeMsByDay = timeMsByDay;
      _videoWatchAtByUid = watchAt;
    });
    // 本地渲染先行，互联数据到达后再增量补位（不阻塞首屏）。
    unawaited(_loadRemoteDashboardData());
  }

  /// 「继续/活动也走 hibiki 互联」：互联启用且已配对时，从 host 拉取
  /// 书清单（内联阅读进度）/ 视频清单（内联播放断点）/ 最近活动事件，
  /// 把本地没有的在读书、在看视频补进「继续」，活动事件与本地混排进时间轴
  /// （display-only 不落库）。任何失败静默保持纯本地视图（离线/老 host 不致崩）。
  Future<void> _loadRemoteDashboardData() async {
    final AppModel appModel = ref.read(appProvider);
    final SyncRepository syncRepo = SyncRepository(appModel.database);
    // 互联是独立开关（已与云备份后端解耦），未启用/未配对直接跳过。
    if (!await syncRepo.isInterconnectEnabled()) return;
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
    if (!await backend.restoreAuth(syncRepo)) return;
    try {
      final List<RemoteBookInfo> remoteBooks = await backend.listRemoteBooks();
      final List<RemoteVideoInfo> remoteVideos =
          await backend.listRemoteVideos();
      final List<RemoteActivityEvent> remoteActivity =
          await backend.listRemoteActivity(limit: 200);
      if (!mounted) return;
      final List<MediaItem> books =
          ref.read(hibikiBooksProvider(appModel.targetLanguage)).valueOrNull ??
              const <MediaItem>[];
      final Set<String> localBookKeys = <String>{
        for (final MediaItem item in books)
          ReaderHibikiSource.parseBookKey(item.mediaIdentifier) ??
              item.mediaIdentifier,
      };
      final Set<String> localVideoUids = <String>{
        for (final VideoBookRow v in _videos) v.bookUid,
      };
      final List<RemoteContinueCandidate> continueCandidates =
          remoteContinueCandidates(
        localBookKeys: localBookKeys,
        localVideoUids: localVideoUids,
        remoteBooks: remoteBooks,
        remoteVideos: remoteVideos,
      );
      // 设备来源标注：配对时存下的 host 设备名（多地址时取第一个启用且有名的）。
      final List<HibikiClientUrl> urls = await syncRepo.getHibikiClientUrls();
      String? deviceName;
      for (final HibikiClientUrl u in urls) {
        final String? name = u.deviceName;
        if (u.enabled && name != null && name.isNotEmpty) {
          deviceName = name;
          break;
        }
      }
      final List<ActivityEventRow> remoteRows =
          remoteActivityAsRows(remoteActivity);
      if (!mounted) return;
      setState(() {
        _remoteContinue = continueCandidates;
        _remoteCoverFetcher = remoteCoverFetcherFor(backend);
        _remoteDeviceName = deviceName;
        _remoteActivityRows = Set<ActivityEventRow>.identity()
          ..addAll(remoteRows);
        _activityEvents = mergeActivityEvents(
          _localActivityEvents,
          remoteRows,
        );
      });
    } catch (_) {
      // 互联瞬断/超时：保持纯本地视图；下次进入首页自然重试。
    }
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

    final Widget continueCard =
        _buildContinueSection(tokens, appModel, books, lastReadByKey);
    final Widget heatmapCard = _buildHeatmapCard(tokens);
    final Widget activityCard = _buildActivitySection(tokens, now);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 900;
        final Widget bodyBelow;
        if (wide) {
          // 热力图置顶通栏后，下方两列并排（左：继续；右：Activity）。整页在纵向滚动的
          // ListView 里，Row 收到的高度约束是无界（h=Infinity）；用 CrossAxisAlignment
          // .start 让两列各自收敛到内容高度，避免 stretch 被迫无限高在 layout 阶段崩溃。
          bodyBelow = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: continueCard),
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
              activityCard,
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.all(tokens.spacing.card),
          children: <Widget>[
            // 区块 1：学习活动热力图，置顶（原顶部统计卡已移除）。
            heatmapCard,
            SizedBox(height: tokens.spacing.card),
            bodyBelow,
          ],
        );
      },
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
    // 互联 host 的远端补位（本地无同 key/uid 的在读书/在看视频），与本地条目
    // 按最近活动时刻统一混排（「继续也走互联」）。
    for (final RemoteContinueCandidate c in _remoteContinue) {
      entries.add(_ContinueEntry(
        isVideo: c.isVideo,
        title: c.title,
        recentMs: c.recentMs,
        percent: c.percent,
        remote: c,
      ));
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
    String subtitle = entry.isVideo
        ? t.home_filter_watch
        : '${t.home_filter_read} · ${entry.percent}%';
    if (entry.remote != null) {
      // 标明设备来源：优先 host 设备名（配对时存下），取不到回退通用「远端」。
      subtitle = '$subtitle · ${_remoteDeviceName ?? t.home_remote_source}';
    }
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
                child: entry.remote != null
                    ? _remoteCover(tokens, entry)
                    : entry.isVideo
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
                                _coverPlaceholder(
                                    tokens, Icons.menu_book_outlined),
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

  /// 远端条目封面：互联 coverUrl + 取图器可用则 [RemoteCoverImage]（按稳定 id
  /// 磁盘缓存），否则占位图标。
  Widget _remoteCover(HibikiDesignTokens tokens, _ContinueEntry entry) {
    final RemoteContinueCandidate remote = entry.remote!;
    final String? coverUrl = remote.coverUrl;
    final RemoteCoverFetcher? fetcher = _remoteCoverFetcher;
    final IconData icon =
        entry.isVideo ? Icons.movie_outlined : Icons.menu_book_outlined;
    if (coverUrl == null || coverUrl.isEmpty || fetcher == null) {
      return _coverPlaceholder(tokens, icon);
    }
    return Image(
      image: RemoteCoverImage(coverUrl, fetcher, cacheKey: remote.id),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _coverPlaceholder(tokens, icon),
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

  /// 打开「继续」条目：本地书走 openMedia，视频切到视频 tab；远端条目切到对应
  /// tab（远端占位卡在那里承接播放/下载，行为与本地视频条目的 tab 跳转一致）。
  Future<void> _openContinueEntry(
    AppModel appModel,
    _ContinueEntry entry,
  ) async {
    if (entry.remote != null) {
      homeShellTabNotifier.value =
          entry.isVideo ? HomeTab.video : HomeTab.books;
      return;
    }
    if (entry.isVideo) {
      homeShellTabNotifier.value = HomeTab.video;
      return;
    }
    final MediaItem item = entry.book!;
    final MediaSource source = item.getMediaSource(appModel: appModel);
    await appModel.openMedia(ref: ref, mediaSource: source, item: item);
  }

  // ── 区块 3：学习活动热力图 ───────────────────────────────────────────────

  /// 学习活动热力图卡（复用 [StatContributionHeatmap]，按每日阅读字数铺格）。
  Widget _buildHeatmapCard(HibikiDesignTokens tokens) {
    return _sectionCard(
      tokens,
      title: t.reading_activity,
      child: StatContributionHeatmap(
        valueByDateKey: _readingCharsByDay,
        now: DateTime.now(),
        baseColor: tokens.surfaces.primary,
        emptyColor: tokens.surfaces.card,
        // 气泡 = 日期 · 字数 · 学习时长（时长为 0 的旧数据/纯导入日不显示时长段）。
        valueLabel: (String dateKey, int chars) {
          final int timeMs = _readingTimeMsByDay[dateKey] ?? 0;
          final String base =
              '${formatStatHeatmapDay(dateKey)} · ${formatStatChars(chars)}';
          return timeMs > 0 ? '$base · ${formatStatTime(timeMs)}' : base;
        },
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
    // 设备来源进聚合：互联对端事件带 host 设备名（identity 识别——远端行 id=0
    // 哨兵且可能与本地行值相等），与本机事件分条展示（「标明设备来源」）。
    final List<ActivityDateGroup> groups = aggregateActivityEvents(
      filtered,
      sourceDeviceOf: (ActivityEventRow e) => _remoteActivityRows.contains(e)
          ? (_remoteDeviceName ?? t.home_remote_source)
          : null,
    );
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
      // 设备来源（互联对端事件带 host 设备名；本机事件不标）。
      if (entry.sourceDevice case final String device) device,
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
