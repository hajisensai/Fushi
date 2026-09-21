/// 库内自动补刮：把「已入库但从未刮出规范身份」的作品捞出来自动刮一轮。
///
/// 判据只有一条：计划器作品对应的规范作品行（`video_metadata_works`，按合集
/// id / bookUid 锚定）不存在，或没有任何作品级 provider 身份——即这个作品从未
/// 被任何资料源认领过（BUG-2000）。带 NFO/TMDB 历史身份的作品视为已刮削，
/// 不重复打扰；整来源重刮走既有 autoAfterScan / 手动入口。
///
/// 自动尝试只做「严格唯一命中」：复用来源刮削管线的解析器，命中→落库写
/// sidecar；歧义/查无→计入 run 的待确认/失败并留在待确认队列里等人工指定。
/// 集号标签型标题（[VideoSourceScrapeWork.hasIdentifiableTitle] 为 false）不做
/// 自动尝试——那类标题要么必失败、要么按目录候选把特典误绑成正片，只该人工
/// 处理（BUG-2001）。**AniDB 哈希就绪时例外**：那正是哈希识别最该派上用场的
/// 场景（按内容认，不看文件名），照常进批次（BUG-2586）。
///
/// 哈希就绪时还多一类排队对象（对齐 Shoko「新文件先哈希」）：作品已有规范身份，
/// 但成员里有还没记过 `anidb_file_identities` 的文件（新下载的一集、新拷进来的
/// 文件）。它们不进待确认清单（作品身份没问题），只静默进批次把文件身份补上。
///
/// 触发：进入视频 tab、切回视频 tab、以及视频库新增条目时（任意导入路径，含
/// 内置下载管线）。批次经 [VideoSourceScrapeTaskController] 走全应用统一互斥门；
/// 忙时直接放弃本轮，下次触发再试。幂等键是**作品**不是进程（BUG-2199），重复
/// 触发廉价。
library;

import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「[since] 之后 TMDB 上有变动的剧 id」探针（生产装配
/// `TmdbVideoMetadataProvider.changedTvShowIds`）。
typedef TmdbChangedTvIdsProbe = Future<Set<int>> Function(
    {required DateTime since});

/// 一条待确认（未识别）作品：来源 + 当前计划里的作品。
///
/// 条目直接从当前计划派生、不落任何新状态：作品存在性由计划器保证，队列里
/// 的「手动指定」永远指向真实存在的作品——不可能再撞
/// `VideoSourceScrapeWorkNotFound`（BUG-1998 的结构性根治）。
class VideoPendingScrapeWork {
  const VideoPendingScrapeWork({required this.source, required this.work});

  final SourceLibraryRow source;
  final VideoSourceScrapeWork work;
}

/// 在所有本地视频来源的刮削计划里定位某个合集对应的作品单元。
///
/// 「重新刮削这个合集」需要的三样东西——来源行、作品标题、稳定键——只有计划器
/// 知道：合集本身不记 sourceId（成员才记），而作品单元是计划器按来源现推出来的。
/// 所以入口不是「查一张表」，而是「问计划器要同一份计划」，与自动补刮、待确认
/// 队列、批次刮削看到的作品定义**逐字节同源**。
///
/// 关键点（BUG-2433）：计划器对同一个合集有**两种同样合法**的表示。成员数 >=2
/// 且文件名解析出集号时，整个合集是一个 `collection:<id>` 单元；否则每个成员各
/// 自是一个 `book:<uid>` 单元——单成员合集、剧场版合集、目录合集都落在后者。
/// 旧实现只按 `collection:<id>` 字面匹配，于是对后者一律报「不在刮削计划里」，
/// 而成员明明就在计划里，用户拿到的是一句假话 + 死胡同。
///
/// 所以定位判据是**成员归属**而不是 key 字面：
/// * 存在合集级单元 -> 只返回它（既有行为一字不变，且它已覆盖全部有集号成员）；
/// * 否则返回该合集成员对应的全部 book 级单元。
///
/// 返回空列表才是真的无从下手——成员全是远端占位、来源已删、成员被特典分类器
/// 判为非正片、或该来源是目录分组模式（计划器对它返回空计划）。调用方据此给可
/// 见提示；返回多个时调用方须让用户选，不得默选第一个（合集里是 N 个独立作品，
/// 猜哪个都可能把身份写错）。
Future<List<VideoPendingScrapeWork>> planScrapeWorksForCollection(
  FushiDatabase database,
  int collectionId,
) async {
  final String stableKey = 'collection:$collectionId';
  final Set<String> memberUids = <String>{
    for (final MediaCollectionItemRow item
        in await database.getCollectionItems(collectionId))
      if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
  };
  final List<SourceLibraryRow> sources =
      (await database.getMediaSourcesByKind('video'))
          .where((SourceLibraryRow source) => source.transport == 'local')
          .toList(growable: false);
  final List<VideoPendingScrapeWork> memberWorks = <VideoPendingScrapeWork>[];
  for (final SourceLibraryRow source in sources) {
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(database).plan(source);
    for (final VideoSourceScrapeWork work in works) {
      if (work.stableKey == stableKey) {
        return <VideoPendingScrapeWork>[
          VideoPendingScrapeWork(source: source, work: work),
        ];
      }
      if (work.collection == null &&
          memberUids.contains(work.members.single.bookUid)) {
        memberWorks.add(VideoPendingScrapeWork(source: source, work: work));
      }
    }
  }
  return List<VideoPendingScrapeWork>.unmodifiable(memberWorks);
}

/// 自动补刮调度器。生命周期跟随 HomePage 的刮削 controller。
class VideoLibraryScrapeSweep {
  VideoLibraryScrapeSweep({
    required FushiDatabase database,
    required VideoSourceScrapeTaskController controller,
    bool Function()? isEnabled,
    bool Function()? isHashReady,
    TmdbChangedTvIdsProbe? tmdbChangedTvIds,
    DateTime Function()? now,
    this.refreshProbeInterval = const Duration(hours: 12),
    this.staleAfter = const Duration(days: 14),
    this.maxRefreshPerSweep = 20,
  })  : _database = database,
        _controller = controller,
        _isEnabled = isEnabled,
        _isHashReady = isHashReady,
        _tmdbChangedTvIds = tmdbChangedTvIds,
        _now = now ?? DateTime.now;

  final FushiDatabase _database;
  final DateTime Function() _now;

  /// 对齐 Shoko 的资料刷新（`TmdbMetadataService.UpdateShow` + 每日
  /// `/tv/changes` 增量）：已识别作品不是刮完就永远不动——
  ///  * 探针每 [refreshProbeInterval] 问一次 TMDB「自最早一次刮削以来谁变了」，
  ///    与本地作品的 TMDB id 求交集，只重刷真变过的（分集补齐、标题/简介修订、
  ///    季结构调整都会触发）；
  ///  * 上次刮削早于 [staleAfter] 的作品超出 changes 回看窗口，直接整部重刷，
  ///    每轮最多 [maxRefreshPerSweep] 部（保护配额，下轮接着刷）。
  /// 重刷走既有 `scrapeWorkSubsets`：已确认身份原样复用（不重新标题搜索）、
  /// 集级链接按新资料重算——Shoko 刷新后 `MatchAnidbToTmdbEpisodes` 重跑、
  /// UserVerified 保留，这里手动指定的身份就是那份 UserVerified。null = 不探针
  /// （测试 / 没有 TMDB）。
  final TmdbChangedTvIdsProbe? _tmdbChangedTvIds;
  final Duration refreshProbeInterval;
  final Duration staleAfter;
  final int maxRefreshPerSweep;
  DateTime? _lastRefreshProbeAt;

  /// 本进程里每部作品最近一次因刷新入批的时刻（同一部在 [refreshProbeInterval]
  /// 内不重复刷）。
  final Map<String, DateTime> _refreshedAt = <String, DateTime>{};

  /// AniDB 哈希识别开关已开且账号 / 客户端配齐（`config.anidbHashReady`）。
  final bool Function()? _isHashReady;
  final VideoSourceScrapeTaskController _controller;

  /// 自动补刮总闸（`AppModel.videoLibraryAutoBackfillScrape`，默认开，设置页
  /// 「视频 → 媒体库」可关）。null = 不设闸（测试）。
  final bool Function()? _isEnabled;

  /// 本进程已自动尝试过的作品（[VideoSourceScrapeWork.stableKey]）。
  ///
  /// 幂等键是**作品**不是进程（BUG-2199）：旧实现用一个 `bool _swept` 编码「这
  /// 一轮跑过了」，于是进视频 tab 那一刻库里有什么就永远只有什么——本次会话里
  /// 下载入库的番（管线 import 落库比首轮 sweep 晚几秒）结构上再也进不来，必须
  /// 重启 app 才被认领，正好废掉 BUG-2004 留下的「无 AniDB 身份的下载作品由自动
  /// 补刮认领」承诺。改成按作品记账后重复触发是廉价的：新作品每次都能进来，而
  /// 查无/歧义的老作品仍只自动试一次——它们永远满足待确认判据，没有这层记账就
  /// 会被每一轮重刮，白占 AniDB 的进程级限流队列。
  final Set<String> _attemptedWorkKeys = <String>{};

  /// 防重入：一轮还在飞时再次触发直接返回（[pendingWorks] 要全量查库）。
  bool _sweeping = false;

  /// 当前所有本地视频来源里「从未刮出规范身份」的作品——待确认队列的数据源。
  Future<List<VideoPendingScrapeWork>> pendingWorks() async =>
      (await _plannedWorks()).pending;

  /// 一次计划两用：待确认清单 + 哈希待补文件所在的已识别作品。
  Future<_PlannedWorks> _plannedWorks() async {
    final List<VideoPendingScrapeWork> pending = <VideoPendingScrapeWork>[];
    final List<VideoPendingScrapeWork> identified = <VideoPendingScrapeWork>[];
    for (final SourceLibraryRow source in await _localVideoSources()) {
      final VideoSourceScrapeSettingRow? settings =
          await _database.getVideoSourceScrapeSettings(source.id);
      if (settings?.enabled == false) continue;
      final List<VideoSourceScrapeWork> works =
          await VideoSourceWorkPlanner(_database).plan(source);
      for (final VideoSourceScrapeWork work in works) {
        (await _hasCanonicalIdentity(work) ? identified : pending)
            .add(VideoPendingScrapeWork(source: source, work: work));
      }
    }
    return _PlannedWorks(pending: pending, identified: identified);
  }

  /// 需要刷新资料的已识别作品（见 [_tmdbChangedTvIds] 的说明）。
  Future<List<VideoPendingScrapeWork>> _refreshBacklog(
      List<VideoPendingScrapeWork> identified) async {
    if (identified.isEmpty) return const <VideoPendingScrapeWork>[];
    final DateTime now = _now();
    final List<VideoPendingScrapeWork> stale = <VideoPendingScrapeWork>[];
    final List<(VideoPendingScrapeWork, int, DateTime)> fresh =
        <(VideoPendingScrapeWork, int, DateTime)>[];
    for (final VideoPendingScrapeWork entry in identified) {
      final DateTime? refreshed = _refreshedAt[entry.work.stableKey];
      if (refreshed != null &&
          now.difference(refreshed) < refreshProbeInterval) {
        continue;
      }
      final VideoMetadataWorkRow? row = await _canonicalWork(entry.work);
      if (row == null) continue;
      final DateTime scrapedAt =
          DateTime.fromMillisecondsSinceEpoch(row.updatedAt);
      if (now.difference(scrapedAt) >= staleAfter) {
        if (stale.length < maxRefreshPerSweep) stale.add(entry);
        continue;
      }
      final int? tmdbId = _tmdbShowId(
          await _database.getVideoMetadataProviderIdentities(workId: row.id),
          row);
      if (tmdbId != null) fresh.add((entry, tmdbId, scrapedAt));
    }
    final List<VideoPendingScrapeWork> result = <VideoPendingScrapeWork>[
      ...stale,
    ];
    final TmdbChangedTvIdsProbe? probe = _tmdbChangedTvIds;
    final DateTime? lastProbe = _lastRefreshProbeAt;
    if (probe != null &&
        fresh.isNotEmpty &&
        (lastProbe == null ||
            now.difference(lastProbe) >= refreshProbeInterval)) {
      DateTime since = fresh.first.$3;
      for (final (_, _, DateTime scrapedAt) in fresh) {
        if (scrapedAt.isBefore(since)) since = scrapedAt;
      }
      _lastRefreshProbeAt = now;
      final Set<int> changed;
      try {
        changed = await probe(since: since);
      } catch (_) {
        // 探针失败只是这一轮不刷；下次到点再问。
        return result;
      }
      for (final (VideoPendingScrapeWork entry, int tmdbId, _) in fresh) {
        if (changed.contains(tmdbId) && result.length < maxRefreshPerSweep) {
          result.add(entry);
        }
      }
    }
    return result;
  }

  /// 作品级 TMDB 剧 id（只对电视剧；电影不走 `/tv/changes`）。
  static int? _tmdbShowId(
      List<VideoMetadataProviderIdentityRow> identities,
      VideoMetadataWorkRow row) {
    if (row.mediaType != VideoMetadataMediaKind.tv.name) return null;
    for (final VideoMetadataProviderIdentityRow identity in identities) {
      if (identity.provider == VideoMetadataProviderKind.tmdb.name) {
        return int.tryParse(identity.externalId);
      }
    }
    return null;
  }

  /// 已识别作品里还有成员没记过文件级 AniDB 身份的那些（哈希待补）。
  Future<List<VideoPendingScrapeWork>> _hashBacklog(
      List<VideoPendingScrapeWork> identified) async {
    if (identified.isEmpty) return const <VideoPendingScrapeWork>[];
    final Set<String> known = await _database.anidbFileIdentityPaths(
        identified.expand((VideoPendingScrapeWork entry) =>
            entry.work.members.map((VideoBookRow m) => m.videoPath)));
    return <VideoPendingScrapeWork>[
      for (final VideoPendingScrapeWork entry in identified)
        if (entry.work.members
            .any((VideoBookRow m) => !known.contains(m.videoPath)))
          entry,
    ];
  }

  /// 自动补刮一轮，并返回当前待确认作品清单。
  ///
  /// 一次查库两用：清单喂视频页的待确认提醒条，其中没自动试过的作品同时进补刮
  /// 批次。总闸关、controller 忙、作品已试过都只是不发起批次，**清单照常返回**
  /// ——「不自动刮」不等于「不告诉用户有东西待确认」。
  Future<List<VideoPendingScrapeWork>> sweepAndListPending() async {
    if (_sweeping) return _pendingWorksOrEmpty();
    _sweeping = true;
    try {
      final _PlannedWorks planned = await _plannedWorksOrEmpty();
      final List<VideoPendingScrapeWork> pending = planned.pending;
      if (_isEnabled != null && !_isEnabled()) return pending;
      // 不排队：已有批次在跑就放弃本轮，避免和手动刮削抢互斥门。
      if (_controller.isBusy) return pending;
      final bool hashReady = _isHashReady?.call() ?? false;
      final Map<SourceLibraryRow, List<VideoSourceScrapeWork>> subsets =
          <SourceLibraryRow, List<VideoSourceScrapeWork>>{};
      final List<String> claimed = <String>[];
      void claim(VideoPendingScrapeWork entry) {
        if (_attemptedWorkKeys.contains(entry.work.stableKey)) return;
        claimed.add(entry.work.stableKey);
        subsets
            .putIfAbsent(entry.source, () => <VideoSourceScrapeWork>[])
            .add(entry.work);
      }

      for (final VideoPendingScrapeWork entry in pending) {
        if (!entry.work.hasIdentifiableTitle && !hashReady) continue;
        claim(entry);
      }
      if (hashReady) {
        for (final VideoPendingScrapeWork entry
            in await _hashBacklog(planned.identified)) {
          claim(entry);
        }
      }
      // 资料刷新（变过的 / 过期的已识别作品）：不走 _attemptedWorkKeys（那是
      // 「查无就不再自动试」的记账，刷新要能周期性重来），按刷新时刻自己记。
      final List<String> refreshing = <String>[];
      for (final VideoPendingScrapeWork entry
          in await _refreshBacklog(planned.identified)) {
        if (claimed.contains(entry.work.stableKey)) continue;
        refreshing.add(entry.work.stableKey);
        subsets
            .putIfAbsent(entry.source, () => <VideoSourceScrapeWork>[])
            .add(entry.work);
      }
      if (subsets.isEmpty) return pending;
      if (_controller.isBusy) return pending;
      // 记账放在真正提交批次前一刻：中途被互斥门挡回的作品不算「已尝试」，
      // 否则本进程再也不会自动碰它们。
      _attemptedWorkKeys.addAll(claimed);
      final DateTime refreshedAt = _now();
      for (final String key in refreshing) {
        _refreshedAt[key] = refreshedAt;
      }
      try {
        await _controller.scrapeWorkSubsets(subsets);
      } catch (_) {
        // 后台静默批次：单轮失败不打扰页面。失败的作品已记账，不反复重试。
      }
      return pending;
    } finally {
      _sweeping = false;
    }
  }

  /// 只补刮、不看清单的调用方入口。
  Future<void> sweepOnce() async {
    await sweepAndListPending();
  }

  Future<List<VideoPendingScrapeWork>> _pendingWorksOrEmpty() async =>
      (await _plannedWorksOrEmpty()).pending;

  Future<_PlannedWorks> _plannedWorksOrEmpty() async {
    try {
      return await _plannedWorks();
    } catch (_) {
      return const _PlannedWorks();
    }
  }

  Future<List<SourceLibraryRow>> _localVideoSources() async =>
      (await _database.getMediaSourcesByKind('video'))
          .where((SourceLibraryRow source) => source.transport == 'local')
          .toList(growable: false);

  Future<VideoMetadataWorkRow?> _canonicalWork(VideoSourceScrapeWork work) =>
      work.collection == null
          ? _database.getVideoMetadataWorkByBook(work.members.single.bookUid)
          : _database.getVideoMetadataWorkByCollection(work.collection!.id);

  /// 规范身份存在判据：works 行存在且至少有一条作品级 provider 身份。合集单元
  /// 没有合集级作品行时，成员**各自**拥有带身份的作品行也算（按 AniDB 作品拆成
  /// 多部电影的目录——它不是待确认，也不该反复进自动补刮）。
  Future<bool> _hasCanonicalIdentity(VideoSourceScrapeWork work) async {
    final VideoMetadataWorkRow? row = await _canonicalWork(work);
    if (row != null) return _hasIdentity(row);
    if (work.collection == null) return false;
    for (final VideoBookRow member in work.members) {
      final VideoMetadataWorkRow? owned =
          await _database.getVideoMetadataWorkByBook(member.bookUid);
      if (owned == null || !await _hasIdentity(owned)) return false;
    }
    return work.members.isNotEmpty;
  }

  Future<bool> _hasIdentity(VideoMetadataWorkRow row) async =>
      (await _database.getVideoMetadataProviderIdentities(workId: row.id))
          .isNotEmpty;
}

class _PlannedWorks {
  const _PlannedWorks({
    this.pending = const <VideoPendingScrapeWork>[],
    this.identified = const <VideoPendingScrapeWork>[],
  });

  /// 没有规范身份的作品（待确认清单 + 自动补刮候选）。
  final List<VideoPendingScrapeWork> pending;

  /// 已有规范身份的作品（只在哈希就绪时看成员是否缺文件身份）。
  final List<VideoPendingScrapeWork> identified;
}
