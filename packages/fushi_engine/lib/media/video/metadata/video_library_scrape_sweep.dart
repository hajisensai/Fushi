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
/// 忙时不发批次、记下请求，批次结束时由调度器自己兑现（监听 controller 的
/// 忙→闲，不依赖视频页挂载）。幂等键是**作品**不是进程
/// （BUG-2199），重复触发廉价。刮削结果落库（含补刮批次自己的写入）**不是**
/// 触发点，只刷新待确认清单（BUG-3072）。
library;

import 'dart:async';

import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:meta/meta.dart';

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
  const VideoPendingScrapeWork({
    required this.source,
    required this.work,
    this.pendingNote,
  });

  final SourceLibraryRow source;
  final VideoSourceScrapeWork work;

  /// 最近一次刮削留下的「为什么没认出来」；近期运行记录里没有它的标记时为 null。
  /// 只有 [VideoLibraryScrapeSweep.pendingWorksWithReasons] 填它（待确认清单要
  /// 显示），计数 / 补刮路径不为它多查运行记录。
  final VideoScrapePendingNote? pendingNote;
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

/// 在视频自己所属来源的刮削计划里定位包含它的作品单元（「重新刮削这个视频」）。
///
/// 与 [planScrapeWorksForCollection] 同一份计划、同一套判据，只是锚点换成单个
/// 成员：独立电影不在任何合集里，合集菜单那条入口对它是断头路（BUG-2737）。
/// 计划器把每个成员恰好分进一个单元，所以答案至多一个——可能是它自己的
/// `book:<uid>` 单元，也可能是它所在剧集的 `collection:<id>` 单元（身份是作品级
/// 的，重刮一集就是重认整部剧）。
///
/// 返回 null：视频不存在，或 [videoBookHasScrapePlan] 不成立。库页入口用同一个判
/// 据决定画不画，所以这里的 null 只剩「菜单打开后来源被改 / 被删」这类竞态；调用
/// 方仍给可见提示。
Future<VideoPendingScrapeWork?> planScrapeWorkForVideoBook(
  FushiDatabase database,
  String bookUid,
) async {
  final VideoBookRow? book = await database.getVideoBookByBookUid(bookUid);
  final int? sourceId = book?.sourceId;
  if (book == null || sourceId == null) return null;
  final SourceLibraryRow? source = await database.getMediaSourceById(sourceId);
  if (source == null || !videoBookHasScrapePlan(book, source)) return null;
  for (final VideoSourceScrapeWork work
      in await VideoSourceWorkPlanner(database).plan(source)) {
    if (work.members.any((VideoBookRow m) => m.bookUid == bookUid)) {
      return VideoPendingScrapeWork(source: source, work: work);
    }
  }
  return null;
}

/// [book] 在它所属来源 [source] 的刮削计划里有没有作品单元、且能被协调器真的刮
/// （BUG-2737）：来源是本机扫描根（远端流 / 互联来源没有本机计划，协调器也只刮
/// `transport == 'local'`），且计划器会为这个来源、这个视频出单元（非目录分组
/// 模式、非特典）。
///
/// 纯函数、不跑计划器：库页「重新刮削」入口用它决定画不画，
/// [planScrapeWorkForVideoBook] 用它提前返回——两处同口径，入口不会画出点了
/// 必然扑空的按钮（手动导入的视频没有 `sourceId`、互联远端下载落在应用目录里，
/// 都在这里被挡掉）。
bool videoBookHasScrapePlan(VideoBookRow book, SourceLibraryRow? source) =>
    source != null &&
    book.sourceId == source.id &&
    source.transport == 'local' &&
    videoSourcePlansScrapeWorks(source) &&
    videoBookJoinsScrapePlan(book);

/// 自动补刮调度器。生命周期跟随 HomePage 的刮削 controller。
class VideoLibraryScrapeSweep {
  VideoLibraryScrapeSweep({
    required FushiDatabase database,
    required VideoSourceScrapeTaskController controller,
    bool Function()? isEnabled,
    bool Function()? isHashReady,
    TmdbChangedTvIdsProbe? tmdbChangedTvIds,
    DateTime Function()? now,
    VideoScrapeSweepLedger? ledger,
    String configFingerprint = '',
    String? Function()? aiCapabilityKey,
    this.refreshProbeInterval = const Duration(hours: 12),
    this.staleAfter = const Duration(days: 14),
    this.maxRefreshPerSweep = 20,
  })  : _database = database,
        _controller = controller,
        _isEnabled = isEnabled,
        _isHashReady = isHashReady,
        _tmdbChangedTvIds = tmdbChangedTvIds,
        _ledger = ledger ?? VideoScrapeSweepLedger(),
        _configFingerprint = configFingerprint,
        _aiCapabilityKey = aiCapabilityKey,
        _now = now ?? DateTime.now {
    _controller.addListener(_onControllerChanged);
  }

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

  /// 「自动试过」「刷新过」「探针问过」三样记账（见 [VideoScrapeSweepLedger]）。
  /// 生产装配落盘、跨进程有效；默认纯内存（= 旧的每进程语义）。
  final VideoScrapeSweepLedger _ledger;

  /// 刮削配置指纹：配置变了，旧配置下「试过没中」的记账作废。
  final String _configFingerprint;

  /// 视频作品识别当前的 AI 能力键（null = 没配 AI），**每轮现取**。
  ///
  /// 「试过没中」是某套刮削配置 + 某套 AI 配置下的结论：没配 AI 时歧义 / 查无的
  /// 作品，配上 AI 后就可能认得出。以前账本指纹只看刮削配置，配好 AI 后旧作品
  /// 还要再等最多 7 天才会重刮、才会问到 AI（2026-10-01）。
  final String? Function()? _aiCapabilityKey;

  /// 账本实际使用的指纹：刮削配置 + AI 能力。没配 AI 时与旧指纹逐字相同——
  /// 不配 AI 的用户（含无头服务端）升级后不该平白清一次账本。
  String get _ledgerFingerprint {
    final String? ai = _aiCapabilityKey?.call();
    return ai == null ? _configFingerprint : '$_configFingerprint|ai=$ai';
  }

  /// AniDB 哈希识别开关已开且账号 / 客户端配齐（`config.anidbHashReady`）。
  final bool Function()? _isHashReady;
  final VideoSourceScrapeTaskController _controller;

  /// 自动补刮总闸（`AppModel.videoLibraryAutoBackfillScrape`，默认开，设置页
  /// 「视频 → 媒体库」可关）。null = 不设闸（测试）。
  final bool Function()? _isEnabled;

  // 已自动尝试过的作品（[VideoSourceScrapeWork.stableKey]）记在 [_ledger] 里。
  //
  // 幂等键是**作品**不是进程（BUG-2199）：旧实现用一个 `bool _swept` 编码「这
  // 一轮跑过了」，于是进视频 tab 那一刻库里有什么就永远只有什么——本次会话里
  // 下载入库的番（管线 import 落库比首轮 sweep 晚几秒）结构上再也进不来，必须
  // 重启 app 才被认领，正好废掉 BUG-2004 留下的「无 AniDB 身份的下载作品由自动
  // 补刮认领」承诺。改成按作品记账后重复触发是廉价的：新作品每次都能进来，而
  // 查无/歧义的老作品在 [VideoScrapeSweepLedger.retryAttemptAfter] 内只自动试一次
  // ——它们永远满足待确认判据，没有这层记账就会被每一轮（旧实现：每次启动）重刮，
  // 白占 AniDB 的进程级限流队列。

  /// 防重入：一轮还在飞时再次触发直接返回（[pendingWorks] 要全量查库）。
  bool _sweeping = false;

  /// 有一次「库里的条目变了」的补刮请求撞上了在飞的一轮（本调度器自己的，或
  /// 别处发起的批次）而没跑成。它不能丢：下载入库常落在批次期间（BUG-2199）。
  /// 由调度器自己兑现：本轮收尾（`finally`）或 controller 忙→闲
  /// （[_onControllerChanged]）。以前只靠视频页「批次忙→闲」时调
  /// [refreshPendingAfterScrapeResults] 兑现——视频页没挂载（用户在别的 tab、
  /// 无头服务端根本没有页面）就一直拖着，页面那边的在飞闸门还可能把这次兑现
  /// 整个吞掉（BUG-3085）。
  ///
  /// 只有 [sweepAndListPending]（库里条目变了的真实请求）会置位它；刮削结果的
  /// 写入（运行记录、作品资料，含补刮批次自己的）绝不置位，否则一轮的写入会
  /// 触发下一轮，临时失败的作品被无限重刮（BUG-3072）。
  bool _sweepDeferred = false;

  /// 最近一次由调度器自己发起的兑现（见 [whenDeferredSettled]）。
  Future<void>? _deferredRun;

  bool _disposed = false;

  /// controller 每次通知都看一眼：有被挡下的请求、自己没在跑、批次已闲 → 兑现。
  /// [sweepAndListPending] 的同步前缀就会置 [_sweeping]，同一轮通知里不会重复发起。
  void _onControllerChanged() {
    if (_disposed || !_sweepDeferred || _sweeping || _controller.isBusy) return;
    _runDeferred();
  }

  void _runDeferred() {
    final Future<void> run = sweepAndListPending().then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) =>
          engineLog.log('VideoLibraryScrapeSweep.deferred', error, stack),
    );
    _deferredRun = run;
  }

  /// 等调度器自己发起的兑现（含兑现期间又被挡下、接着再跑的那一轮）全部跑完。
  @visibleForTesting
  Future<void> whenDeferredSettled() async {
    while (true) {
      final Future<void>? run = _deferredRun;
      if (run == null) return;
      await run;
      if (identical(run, _deferredRun)) return;
    }
  }

  /// 断开与 controller 的监听。controller 换代 / 关停前调用：之后在途批次结束
  /// 也不会再由这一代调度器发起补刮。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_onControllerChanged);
  }

  /// 最近一次算出的待确认清单。批次在跑（含本调度器自己发起的那一批）时，
  /// 重复触发直接回它：每次重算都要把所有来源重新规划一遍 + 逐作品查身份，
  /// 批次期间每写一部作品就触发一次，正是刮削时库页卡顿的来源之一。批次结束
  /// 后库页会再触发一轮，届时重算。
  List<VideoPendingScrapeWork> _lastPending = const <VideoPendingScrapeWork>[];

  /// 当前所有本地视频来源里「从未刮出规范身份」的作品——待确认队列的数据源。
  /// 只读：不发起补刮。
  Future<List<VideoPendingScrapeWork>> pendingWorks() async =>
      _lastPending = (await _plannedWorks()).pending;

  /// 刮削结果落库 / 批次结束后刷新待确认清单（提醒条计数）。
  ///
  /// 只读，**不**发起补刮——刮削结果的写入（含补刮批次自己的）会触发这里，若它
  /// 也发起补刮，一轮的写入就会启动下一轮（BUG-3072）。批次期间被挡下的真实请求
  /// 由调度器自己在批次结束时兑现（[_onControllerChanged]），不经这里。
  Future<List<VideoPendingScrapeWork>> refreshPendingAfterScrapeResults() =>
      pendingWorks();

  /// 同 [pendingWorks]，每部作品再带上最近一次刮削留下的挂起原因（见
  /// `video_scrape_pending_note.dart`）。待确认清单用；只要计数的地方别用它。
  Future<List<VideoPendingScrapeWork>> pendingWorksWithReasons() async =>
      _withPendingNotes(await pendingWorks());

  /// 每个来源回看多少次「留下了待确认 / 失败作品」的运行：挂起原因只要最近的，
  /// 全部成功的运行不占窗口（见 `getUnresolvedVideoSourceScrapeRuns`）。
  static const int _pendingNoteRunLookback = 20;

  Future<List<VideoPendingScrapeWork>> _withPendingNotes(
      List<VideoPendingScrapeWork> pending) async {
    final Map<int, Map<String, VideoScrapePendingNote>> bySource =
        <int, Map<String, VideoScrapePendingNote>>{};
    for (final VideoPendingScrapeWork entry in pending) {
      bySource[entry.source.id] ??= await _pendingNotesOf(entry.source.id);
    }
    return <VideoPendingScrapeWork>[
      for (final VideoPendingScrapeWork entry in pending)
        VideoPendingScrapeWork(
          source: entry.source,
          work: entry.work,
          pendingNote: bySource[entry.source.id]![entry.work.stableKey],
        ),
    ];
  }

  Future<Map<String, VideoScrapePendingNote>> _pendingNotesOf(
      int sourceId) async {
    final List<VideoSourceScrapeRunRow> runs =
        await _database.getUnresolvedVideoSourceScrapeRuns(
            sourceId: sourceId, limit: _pendingNoteRunLookback);
    return latestVideoScrapePendingNotes(<Iterable<String>>[
      for (final VideoSourceScrapeRunRow run in runs)
        if (decodeSourceScrapeReport(run.summaryJson)
            case final SourceScrapeReport report)
          <String>[
            for (final SourceScrapeIssue issue in report.warnings) issue.message,
            for (final SourceScrapeIssue issue in report.errors) issue.message,
          ],
    ]);
  }

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
      final DateTime? refreshed = _ledger.refreshedAt(entry.work.stableKey);
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
    final DateTime? lastProbe = _ledger.lastRefreshProbeAt;
    if (probe != null &&
        fresh.isNotEmpty &&
        (lastProbe == null ||
            now.difference(lastProbe) >= refreshProbeInterval)) {
      DateTime since = fresh.first.$3;
      for (final (_, _, DateTime scrapedAt) in fresh) {
        if (scrapedAt.isBefore(since)) since = scrapedAt;
      }
      _ledger.markRefreshProbe(now);
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
  /// 只在「库里可能有新作品」时调用（进视频页、条目集合变化、服务端扫描后）；
  /// 刮削结果变化走 [refreshPendingAfterScrapeResults]。
  ///
  /// 一次查库两用：清单喂视频页的待确认提醒条，其中没自动试过的作品同时进补刮
  /// 批次。总闸关、controller 忙、作品已试过都只是不发起批次，**清单照常返回**
  /// ——「不自动刮」不等于「不告诉用户有东西待确认」。
  Future<List<VideoPendingScrapeWork>> sweepAndListPending() async {
    if (_sweeping || _controller.isBusy) return _deferUntilIdle(_lastPending);
    _sweeping = true;
    _sweepDeferred = false;
    try {
      final _PlannedWorks planned = await _plannedWorksOrEmpty();
      final List<VideoPendingScrapeWork> pending = _lastPending = planned.pending;
      if (_isEnabled != null && !_isEnabled()) return pending;
      // 不排队：已有批次在跑就不发批次，避免和手动刮削抢互斥门；请求记下，
      // 批次结束时兑现。
      if (_controller.isBusy) return _deferUntilIdle(pending);
      await _ledger.ensureLoaded(fingerprint: _ledgerFingerprint);
      final DateTime startedAt = _now();
      final bool hashReady = _isHashReady?.call() ?? false;
      final Map<SourceLibraryRow, List<VideoSourceScrapeWork>> subsets =
          <SourceLibraryRow, List<VideoSourceScrapeWork>>{};
      final List<String> claimed = <String>[];
      void claim(VideoPendingScrapeWork entry) {
        if (_ledger.wasAttemptedRecently(entry.work.stableKey, startedAt)) {
          return;
        }
        claimed.add(entry.work.stableKey);
        subsets
            .putIfAbsent(entry.source, () => <VideoSourceScrapeWork>[])
            .add(entry.work);
      }

      // 下载任务确认过身份的作品不看标题能不能认：协调器会照那份身份直取
      // （见 `downloadConfirmedLookupsForWorks`）。
      final Set<String> downloadConfirmed = (await _downloadConfirmedKeys(
        pending,
      ));
      for (final VideoPendingScrapeWork entry in pending) {
        if (!entry.work.hasIdentifiableTitle &&
            !hashReady &&
            !downloadConfirmed.contains(entry.work.stableKey)) {
          continue;
        }
        claim(entry);
      }
      if (hashReady) {
        for (final VideoPendingScrapeWork entry
            in await _hashBacklog(planned.identified)) {
          claim(entry);
        }
      }
      // 资料刷新（变过的 / 过期的已识别作品）：不走「自动试过」记账（那是
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
      if (subsets.isEmpty) {
        await _saveLedger();
        return pending;
      }
      if (_controller.isBusy) return _deferUntilIdle(pending);
      // 记账放在真正提交批次前一刻：中途被互斥门挡回的作品不算「已尝试」，
      // 否则再也不会自动碰它们。
      final DateTime submittedAt = _now();
      _ledger.markAttempted(claimed, submittedAt);
      _ledger.markRefreshed(refreshing, submittedAt);
      await _saveLedger();
      try {
        final SourceScrapeReport report =
            await _controller.scrapeWorkSubsets(subsets);
        // 只因资料源 / AI 临时不可用（504 / 握手失败 / 超时 / 限流 / AI 请求失败）
        // 而没认出的作品不是「查无」：改按短间隔
        // （[VideoScrapeSweepLedger.transientRetryAfter]）退避，而不是挡 7 天
        // （BUG-2796）；也不是直接撤账——撤账后任意一次触发都会重新认领它，
        // 资料源连不上期间同一作品被反复重刮（BUG-3072）。AI 失败记在 warnings
        // （作品本身是待确认，不算错）。
        final List<String> transient = <String>[
          for (final SourceScrapeIssue issue in <SourceScrapeIssue>[
            ...report.errors,
            ...report.warnings,
          ])
            if (issue.providerUnavailable &&
                issue.workKey != null &&
                claimed.contains(issue.workKey))
              issue.workKey!,
        ];
        if (transient.isNotEmpty) {
          _ledger.markTransientFailure(transient, _now());
          await _saveLedger();
        }
      } catch (_) {
        // 后台静默批次：单轮失败不打扰页面。失败的作品已记账，不反复重试。
      }
      return pending;
    } finally {
      _sweeping = false;
      // 本轮在飞期间有条目变化被挡下：这里兑现（控制器仍忙则等它忙→闲时由
      // [_onControllerChanged] 兑现）。
      if (!_disposed && _sweepDeferred && !_controller.isBusy) {
        _runDeferred();
      }
    }
  }

  List<VideoPendingScrapeWork> _deferUntilIdle(
      List<VideoPendingScrapeWork> pending) {
    _sweepDeferred = true;
    return pending;
  }

  Future<void> _saveLedger() =>
      _ledger.save(now: _now(), refreshWindow: refreshProbeInterval);

  /// 只补刮、不看清单的调用方入口。
  Future<void> sweepOnce() async {
    await sweepAndListPending();
  }

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

  Future<Set<String>> _downloadConfirmedKeys(
    List<VideoPendingScrapeWork> pending,
  ) async {
    try {
      return (await downloadConfirmedLookupsForWorks(_database, <VideoSourceScrapeWork>[
        for (final VideoPendingScrapeWork entry in pending) entry.work,
      ]))
          .keys
          .toSet();
    } catch (error, stack) {
      // 查不到下载记录只是少一条「绕过标题判据」的通道，照常按标题补刮；原因
      // 必须留痕。
      engineLog.log('VideoLibraryScrapeSweep.downloadConfirmed', error, stack);
      return const <String>{};
    }
  }

  Future<VideoMetadataWorkRow?> _canonicalWork(VideoSourceScrapeWork work) =>
      canonicalVideoMetadataWork(_database, work);

  Future<bool> _hasCanonicalIdentity(VideoSourceScrapeWork work) =>
      hasCanonicalVideoMetadataIdentity(_database, work);
}

/// 计划器作品对应的规范作品行（按合集 id / bookUid 锚定）。
Future<VideoMetadataWorkRow?> canonicalVideoMetadataWork(
  FushiDatabase database,
  VideoSourceScrapeWork work,
) =>
    work.collection == null
        ? database.getVideoMetadataWorkByBook(work.members.single.bookUid)
        : database.getVideoMetadataWorkByCollection(work.collection!.id);

/// 规范身份存在判据：works 行存在且至少有一条作品级 provider 身份。合集单元
/// 没有合集级作品行时，成员**各自**拥有带身份的作品行也算（按 AniDB 作品拆成
/// 多部电影的目录——它不是待确认，也不该反复进自动补刮）。
///
/// 补刮（选谁进批次）与协调器（下载确认身份只给还没有规范身份的作品，不覆盖
/// 用户后来手动改过的绑定）共用这一个判据。
Future<bool> hasCanonicalVideoMetadataIdentity(
  FushiDatabase database,
  VideoSourceScrapeWork work,
) async {
  Future<bool> hasIdentity(VideoMetadataWorkRow row) async =>
      (await database.getVideoMetadataProviderIdentities(workId: row.id))
          .isNotEmpty;
  final VideoMetadataWorkRow? row =
      await canonicalVideoMetadataWork(database, work);
  if (row != null) return hasIdentity(row);
  if (work.collection == null) return false;
  for (final VideoBookRow member in work.members) {
    final VideoMetadataWorkRow? owned =
        await database.getVideoMetadataWorkByBook(member.bookUid);
    if (owned == null || !await hasIdentity(owned)) return false;
  }
  return work.members.isNotEmpty;
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
