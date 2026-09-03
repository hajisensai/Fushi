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
/// 处理（BUG-2001）。
///
/// 触发：进入视频 tab（每进程一次）。批次经 [VideoSourceScrapeTaskController]
/// 走全应用统一互斥门；忙时直接放弃本轮，下次进程再试。
library;

import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

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

/// 自动补刮调度器。生命周期跟随 HomePage 的刮削 controller。
class VideoLibraryScrapeSweep {
  VideoLibraryScrapeSweep({
    required FushiDatabase database,
    required VideoSourceScrapeTaskController controller,
    bool Function()? isEnabled,
  })  : _database = database,
        _controller = controller,
        _isEnabled = isEnabled;

  final FushiDatabase _database;
  final VideoSourceScrapeTaskController _controller;

  /// 自动补刮总闸（`AppModel.videoLibraryAutoBackfillScrape`，默认开，设置页
  /// 「视频 → 媒体库」可关）。null = 不设闸（测试）。
  final bool Function()? _isEnabled;

  bool _swept = false;

  /// 当前所有本地视频来源里「从未刮出规范身份」的作品——待确认队列的数据源。
  Future<List<VideoPendingScrapeWork>> pendingWorks() async {
    final List<VideoPendingScrapeWork> pending = <VideoPendingScrapeWork>[];
    for (final SourceLibraryRow source in await _localVideoSources()) {
      final VideoSourceScrapeSettingRow? settings =
          await _database.getVideoSourceScrapeSettings(source.id);
      if (settings?.enabled == false) continue;
      final List<VideoSourceScrapeWork> works =
          await VideoSourceWorkPlanner(_database).plan(source);
      for (final VideoSourceScrapeWork work in works) {
        if (!await _hasCanonicalIdentity(work)) {
          pending.add(VideoPendingScrapeWork(source: source, work: work));
        }
      }
    }
    return pending;
  }

  /// 每进程一轮的自动补刮。幂等：跑过、总闸关、controller 忙都直接返回。
  Future<void> sweepOnce() async {
    if (_swept) return;
    if (_isEnabled != null && !_isEnabled()) return;
    // 不排队：已有批次在跑就放弃本轮，避免和手动刮削抢互斥门。
    if (_controller.isBusy) return;
    _swept = true;
    try {
      final Map<SourceLibraryRow, List<VideoSourceScrapeWork>> subsets =
          <SourceLibraryRow, List<VideoSourceScrapeWork>>{};
      for (final VideoPendingScrapeWork entry in await pendingWorks()) {
        if (!entry.work.hasIdentifiableTitle) continue;
        subsets
            .putIfAbsent(entry.source, () => <VideoSourceScrapeWork>[])
            .add(entry.work);
      }
      if (subsets.isEmpty) return;
      if (_controller.isBusy) return;
      await _controller.scrapeWorkSubsets(subsets);
    } catch (_) {
      // 后台静默批次：单轮失败不打扰页面，下次启动自然重试。
    }
  }

  Future<List<SourceLibraryRow>> _localVideoSources() async =>
      (await _database.getMediaSourcesByKind('video'))
          .where((SourceLibraryRow source) => source.transport == 'local')
          .toList(growable: false);

  /// 规范身份存在判据：works 行存在且至少有一条作品级 provider 身份。
  Future<bool> _hasCanonicalIdentity(VideoSourceScrapeWork work) async {
    final VideoMetadataWorkRow? row = work.collection == null
        ? await _database
            .getVideoMetadataWorkByBook(work.members.single.bookUid)
        : await _database.getVideoMetadataWorkByCollection(work.collection!.id);
    if (row == null) return false;
    final List<VideoMetadataProviderIdentityRow> identities =
        await _database.getVideoMetadataProviderIdentities(workId: row.id);
    return identities.isNotEmpty;
  }
}
