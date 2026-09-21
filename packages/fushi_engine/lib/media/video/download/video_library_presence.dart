/// 「这部作品在本地已经有哪些集」的公共判据。
///
/// 订阅调度器（`video_download_subscription_service.dart`）与 AI 下载流程共用
/// 同一份答案：一集要么已经有下载任务在管它的文件，要么已经作为视频条目入了
/// 作品对应的合集。两边只能问这里，不各自扫一遍任务表 / 合集表再各自解释。
///
/// 语义是**单身份**的：一次调用只回答「某 provider 的某个 externalId」这一对
/// 身份在本地的存在情况。调用方若手上有同一作品的多个跨源 id（AniDB / MAL /
/// TMDB…），自己逐对查再合并，这里不做跨源映射。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 逻辑集的稳定键，`S01E05` 形态（季 / 集各至少两位补零）。
///
/// 订阅条目的 `logicalItemKey`、下载任务文件的集号判重都用这一个形态。
String videoEpisodeKey(int season, int episode) =>
    'S${season.toString().padLeft(2, '0')}'
    'E${episode.toString().padLeft(2, '0')}';

final RegExp _episodeKeyEpisodePattern = RegExp(r'E(\d+)$');

/// 一部作品（按单个 provider 身份）在本地库的存在情况。
class VideoLibraryPresence {
  const VideoLibraryPresence({
    this.workId,
    this.collectionId,
    required this.managedEpisodeKeys,
  });

  /// 什么都没有：身份为空、或本地既无任务也无作品。
  static const VideoLibraryPresence none = VideoLibraryPresence(
    managedEpisodeKeys: <String>{},
  );

  /// 命中的 `video_metadata_works.id`；本地没刮到这部作品则为 null。
  final int? workId;

  /// 作品挂着的合集 id；作品未入库（或没刮到）则为 null。
  final int? collectionId;

  /// 已经有人管的集（[videoEpisodeKey] 形态）：活跃 / 已完成任务的文件 +
  /// 合集里按文件名解析出集号的视频条目。
  final Set<String> managedEpisodeKeys;

  /// 本地已经刮到这部作品（合集或单本都算）。只看作品身份，不看有没有集。
  bool get inLibrary => workId != null;

  /// [managedEpisodeKeys] 里最大的集号（**跨季**）；一集都没有则为 null。
  ///
  /// 键只剥 `E(\d+)`，不区分 `S01E12` 与 `S02E03` 谁在后面；要按季比较用
  /// [highestEpisodeOf]。
  int? get highestEpisode => _highest(managedEpisodeKeys);

  /// 第 [season] 季里最大的集号；这一季一集都没有则为 null。
  int? highestEpisodeOf(int season) {
    final String prefix = 'S${season.toString().padLeft(2, '0')}E';
    return _highest(
        managedEpisodeKeys.where((String k) => k.startsWith(prefix)));
  }

  static int? _highest(Iterable<String> keys) {
    int? highest;
    for (final String key in keys) {
      final RegExpMatch? match = _episodeKeyEpisodePattern.firstMatch(key);
      if (match == null) continue;
      final int? episode = int.tryParse(match.group(1)!);
      if (episode == null) continue;
      if (highest == null || episode > highest) highest = episode;
    }
    return highest;
  }
}

/// 解析 `metadataProvider` / `externalId` 这一对身份在本地库的存在情况。
///
/// - [mediaKind] 为电影时没有集可扫（订阅侧用 `movie` 逻辑键判重），但作品
///   身份照查：`inLibrary` / `workId` 对已刮到的剧场版必须为真，否则 AI 下载
///   流程会把库里已有的电影再下一遍。
/// - provider 归一为 `trim().toLowerCase()`、externalId 归一为 `trim()`；
///   归一后任一为空也返回 [VideoLibraryPresence.none]。
/// - 任务扫描与合集扫描的取舍见函数体内注释。
Future<VideoLibraryPresence> resolveVideoLibraryPresence(
  FushiDatabase database, {
  required String metadataProvider,
  required String externalId,
  required VideoMetadataMediaKind mediaKind,
}) async {
  final String provider = metadataProvider.trim().toLowerCase();
  final String normalizedExternalId = externalId.trim();
  if (provider.isEmpty || normalizedExternalId.isEmpty) {
    return VideoLibraryPresence.none;
  }
  if (mediaKind == VideoMetadataMediaKind.movie) {
    final VideoMetadataWorkRow? work =
        await database.getVideoMetadataWorkByProviderIdentity(
      provider: provider,
      externalId: normalizedExternalId,
    );
    return VideoLibraryPresence(
      workId: work?.id,
      collectionId: work?.collectionId,
      managedEpisodeKeys: const <String>{},
    );
  }
  final Set<String> result = <String>{};
  bool sameIdentity(VideoDownloadJobRow job) =>
      job.metadataProvider?.trim().toLowerCase() == provider &&
      job.externalId?.trim() == normalizedExternalId;
  for (final VideoDownloadJobRow job in await database.getVideoDownloadJobs()) {
    // 只有 active / completed 的任务才算「这一集的文件已经有人管」。
    //
    // 这份判据与订阅侧的 `subscriptionItemStillClaimed` **不同**且有意不同：
    // 那边按「是谁决定不下的」划，cancelled 算数；这边按「文件到底有没有人在
    // 弄」划，cancelled 不算数。needsAttention 归到不算数一侧：它正是订阅这一轮
    // 要恢复的对象（见订阅服务的 `_enqueueItem`），留着它，同一条卡住的任务会
    // 在文件级把自己的订阅条目判成「已经有人管」而走 `_markItemSkipped` —— 那
    // 是个终态写入，此后 `subscriptionItemStillClaimed` 永远返回 true，这一集被
    // 静默判了永久跳过。真正已经入库的集数由下面的 collection items 那一段兜
    // 住，不依赖这里的任务扫描。
    final bool jobOwnsEpisodeFiles =
        job.lifecycle == VideoDownloadJobLifecycle.active ||
            job.lifecycle == VideoDownloadJobLifecycle.completed;
    if (!sameIdentity(job) || !jobOwnsEpisodeFiles) continue;
    for (final VideoDownloadJobFileRow file
        in await database.getVideoDownloadJobFiles(job.jobId)) {
      final int? season = file.season;
      final int? episode = file.episode;
      if (season == null || episode == null || episode <= 0) continue;
      if (file.status == VideoDownloadJobFileStatus.failed ||
          file.status == VideoDownloadJobFileStatus.skipped) {
        continue;
      }
      result.add(videoEpisodeKey(season, episode));
    }
  }

  final VideoMetadataWorkRow? work =
      await database.getVideoMetadataWorkByProviderIdentity(
    provider: provider,
    externalId: normalizedExternalId,
  );
  final int? collectionId = work?.collectionId;
  if (work == null || collectionId == null) {
    return VideoLibraryPresence(
      workId: work?.id,
      managedEpisodeKeys: result,
    );
  }
  for (final MediaCollectionItemRow item
      in await database.getCollectionItems(collectionId)) {
    if (item.mediaType != MediaKind.video.dbValue) continue;
    final VideoBookRow? book =
        await database.getVideoBookByBookUid(item.entryKey);
    if (book == null) continue;
    final VideoNameInfo parsed = parseVideoFilename(book.videoPath);
    final int? episode = parsed.episode;
    if (episode == null || episode <= 0) continue;
    result.add(videoEpisodeKey(parsed.season ?? 1, episode));
  }
  return VideoLibraryPresence(
    workId: work.id,
    collectionId: collectionId,
    managedEpisodeKeys: result,
  );
}
