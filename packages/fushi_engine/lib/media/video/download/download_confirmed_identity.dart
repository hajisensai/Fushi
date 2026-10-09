/// 下载任务确认过的作品身份，以及「这条任务对应库里的哪部作品」。
///
/// 下载入队时用户已经确认过身份（发现页 / AI 下视频选定的作品），它存在任务行
/// 里（`identity_json` + `metadata_provider` / `external_id`）。这份身份是持久的：
/// 下载管线的 scrape 阶段用它，库内自动补刮 / 整源刮削在作品还没有规范身份时也用
/// 它——否则一次资料源临时故障就让「用户确认过的身份」永久丢失，补刮只能退回按
/// 标题搜（俗称 / 译名搜不到，歧义还要人工确认）。
///
/// 两边必须用**同一个**「任务 → 作品」判据（[downloadJobWork]），不然同一个身份
/// 会被绑到不同作品上。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/discovery/discovery_metadata_identity.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show kManualVideoDownloadResourceProvider;
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';

/// 任务行 → 入队时确认的作品引用。
VideoMediaReference videoDownloadJobMediaReference(VideoDownloadJobRow job) {
  final VideoMetadataMediaKind mediaKind =
      VideoMetadataMediaKind.values.asNameMap()[job.mediaKind] ??
      VideoMetadataMediaKind.tv;
  final VideoDiscoveryCategory category =
      VideoDiscoveryCategory.values.asNameMap()[job.discoveryCategory] ??
      (mediaKind == VideoMetadataMediaKind.movie
          ? VideoDiscoveryCategory.movie
          : VideoDiscoveryCategory.tv);
  // v94（BUG-2003）：身份面（原名/别名/全部外部 id）从入队快照恢复——字幕
  // 搜索从此拿得到日文原名与罗马字别名。任务列（title/year/season/kind）仍是
  // 用户可见与流程真值。旧行（NULL 快照）走修前的单 id 重建。
  final VideoMediaReference? stored = decodeVideoMediaReference(
    job.identityJson,
  );
  if (stored != null) {
    // 任务形态被整理器改判过（BUG-2760：电影身份配上多集合集包）：TMDB 的
    // /movie 与 /tv 是两个 id 空间，IMDb 的电影条目也不是剧集条目。这些 id
    // 描述的是**另一部作品**，带着它们刮削/搜字幕只会绑错，丢掉交给自动识别；
    // MAL / AniDB 等不分形态的 id 照旧保留。
    final bool kindDrifted = stored.mediaKind != mediaKind;
    final bool tmdbIdentity = stored.providerId.toLowerCase() == 'tmdb';
    return VideoMediaReference(
      providerId: kindDrifted && tmdbIdentity ? 'unknown' : stored.providerId,
      mediaId: stored.mediaId,
      mediaKind: mediaKind,
      discoveryCategory: category,
      title: job.title,
      originalTitle: stored.originalTitle,
      aliases: stored.aliases,
      year: job.year ?? stored.year,
      season: job.season ?? stored.season,
      tmdbId: kindDrifted ? null : stored.tmdbId,
      imdbId: kindDrifted ? null : stored.imdbId,
      tvdbId: stored.tvdbId,
      anidbId: stored.anidbId,
      anilistId: stored.anilistId,
      bangumiId: stored.bangumiId,
      externalIds: kindDrifted
          ? <String, String>{
              for (final MapEntry<String, String> entry
                  in stored.externalIds.entries)
                if (entry.key.toLowerCase() != 'tmdb' &&
                    entry.key.toLowerCase() != 'imdb')
                  entry.key: entry.value,
            }
          : stored.externalIds,
    );
  }
  final String provider = job.metadataProvider ?? 'unknown';
  final String id = job.externalId ?? job.title;
  return VideoMediaReference(
    providerId: provider,
    mediaId: id,
    mediaKind: mediaKind,
    discoveryCategory: category,
    title: job.title,
    year: job.year,
    season: job.season,
    anidbId: provider == 'anidb' ? int.tryParse(id) : null,
    tmdbId: provider == 'tmdb' ? int.tryParse(id) : null,
    anilistId: provider == 'anilist' ? int.tryParse(id) : null,
    bangumiId: provider == 'bangumi' ? int.tryParse(id) : null,
  );
}

/// 任务确认的刮削身份（[videoDownloadJobConfirmedLookups] 的首选）；拿不出可直取
/// 的 id 时为 null。
///
/// 下载管线的 scrape 阶段与库内补刮都只认这一个判据。
VideoMetadataLookup? videoDownloadJobConfirmedLookup(VideoDownloadJobRow job) =>
    videoDownloadJobConfirmedLookups(job).firstOrNull;

/// 任务记下的**全部**可直取身份，首选在前：手动任务显式给的 AniDB 身份（用户亲手
/// 指定、且是默认主源）排第一，其后是入队快照里的 MAL → TMDB
/// （[videoDiscoveryMetadataLookups]）。一家资料源连不上时后面的 id 照样可用
/// （BUG-3073）；单条判据 [videoDownloadJobConfirmedLookup] 与库内补刮的列表判据
/// [downloadConfirmedLookupListsForWorks] 都从这里取，两边不会各认各的。
List<VideoMetadataLookup> videoDownloadJobConfirmedLookups(
  VideoDownloadJobRow job,
) {
  final VideoMetadataLookup? manualAniDb = _manualAniDbLookup(job);
  return <VideoMetadataLookup>[
    ?manualAniDb,
    for (final VideoMetadataLookup lookup in videoDiscoveryMetadataLookups(
      videoDownloadJobMediaReference(job),
    ))
      if (manualAniDb == null || !_sameLookup(lookup, manualAniDb)) lookup,
  ];
}

/// 手动任务（互联代下载 / `fushi_server ctl downloads add --provider anidb`）由用户
/// **显式**给出的 AniDB 身份：AniDB 是默认主源，刮削协调器直接认它。
///
/// 只认手动任务行上的 `metadata_provider = anidb`：发现页旧快照里顺带的 AniDB
/// 交叉引用（`identity_json` 里的 anidbId）一直不算确认身份（那些任务按 MAL /
/// TMDB 或自动识别走），这里不改它们的去向。
VideoMetadataLookup? _manualAniDbLookup(VideoDownloadJobRow job) {
  if (job.resourceProvider != kManualVideoDownloadResourceProvider ||
      job.identityJson != null ||
      job.metadataProvider?.toLowerCase() != 'anidb') {
    return null;
  }
  final int? id = int.tryParse(job.externalId?.trim() ?? '');
  final VideoMetadataMediaKind? kind =
      VideoMetadataMediaKind.values.asNameMap()[job.mediaKind];
  if (id == null || id <= 0 || kind == null) return null;
  return VideoMetadataLookup(
    provider: VideoMetadataProviderKind.anidb,
    externalId: '$id',
    mediaKind: kind,
  );
}

/// movie 形态 job 的主片行：最大 `sizeBytes`（与组织器抬正片的判据一致；
/// 平手取列表里先出现的行）。旧行没记体积时按 0 参与比较。
VideoDownloadJobFileRow? mainMovieDownloadFile(
  List<VideoDownloadJobFileRow> files,
) {
  VideoDownloadJobFileRow? main;
  for (final VideoDownloadJobFileRow file in files) {
    if (main == null || (file.sizeBytes ?? 0) > (main.sizeBytes ?? 0)) {
      main = file;
    }
  }
  return main;
}

/// 任务下到库里的视频文件（规范化路径）。
Set<String> downloadJobImportedVideoPaths(List<VideoDownloadJobFileRow> files) =>
    <String>{
      for (final VideoDownloadJobFileRow row in files)
        if (row.kind == 'video' && row.finalAbsolutePath != null)
          normalizeVideoPath(row.finalAbsolutePath!),
    };

/// 在 [works] 里包含任务导入文件的那些作品。
List<VideoSourceScrapeWork> downloadJobPathMatches(
  List<VideoDownloadJobFileRow> files,
  List<VideoSourceScrapeWork> works,
) {
  final Set<String> importedPaths = downloadJobImportedVideoPaths(files);
  return works
      .where(
        (VideoSourceScrapeWork work) => work.members.any(
          (VideoBookRow member) =>
              importedPaths.contains(normalizeVideoPath(member.videoPath)),
        ),
      )
      .toList(growable: false);
}

/// 这条任务的确认身份属于 [works] 里的哪一部；说不清（文件散在多部作品里且没有
/// 一部是任务的合集、也不是能挑出主片的电影包）为 null——宁可不绑，也不猜。
VideoSourceScrapeWork? downloadJobWork(
  VideoDownloadJobRow job,
  List<VideoDownloadJobFileRow> files,
  List<VideoSourceScrapeWork> works,
) {
  final List<VideoSourceScrapeWork> pathMatches = downloadJobPathMatches(
    files,
    works,
  );
  if (job.collectionId != null) {
    // 新入库的剧可能只有一集：计划器有意不把单成员合集提成剧集作品，它的精确
    // 路径匹配里就没有合集。那一个无歧义的路径匹配照样认——仍是按身份、不按
    // 标题比较。
    return pathMatches
            .where(
              (VideoSourceScrapeWork value) =>
                  value.collection?.id == job.collectionId,
            )
            .firstOrNull ??
        (pathMatches.length == 1 ? pathMatches.single : null);
  }
  if (pathMatches.length == 1) return pathMatches.single;
  if (pathMatches.length > 1 &&
      job.mediaKind == VideoMetadataMediaKind.movie.name) {
    // 多部电影一个种子（BUG-2007）：确认身份只属于用户选定的那一部（= 主片）。
    // 并列正片留给自动识别 / 人工认领——整批强绑必然误绑。
    final VideoDownloadJobFileRow? movieMain = mainMovieDownloadFile(
      files
          .where(
            (VideoDownloadJobFileRow row) =>
                row.kind == 'video' && row.finalAbsolutePath != null,
          )
          .toList(),
    );
    if (movieMain == null) return null;
    final String mainPath = normalizeVideoPath(movieMain.finalAbsolutePath!);
    return pathMatches
        .where(
          (VideoSourceScrapeWork value) => value.members.any(
            (VideoBookRow member) =>
                normalizeVideoPath(member.videoPath) == mainPath,
          ),
        )
        .firstOrNull;
  }
  return null;
}

/// [works] 里每部由下载任务产出的作品 → 任务确认的身份（按 stableKey）。
///
/// 一部作品可能来自多条任务（逐集下载）：身份一致才收，不一致（用户先后确认了
/// 不同作品）就不替它选。「作品已经有规范身份就不该覆盖」由调用方判断——那是刮削
/// 层的优先级，这里只回答「下载确认过什么」。
Future<Map<String, VideoMetadataLookup>> downloadConfirmedLookupsForWorks(
  FushiDatabase database,
  List<VideoSourceScrapeWork> works,
) async =>
    <String, VideoMetadataLookup>{
      for (final MapEntry<String, List<VideoMetadataLookup>> entry
          in (await downloadConfirmedLookupListsForWorks(database, works))
              .entries)
        entry.key: entry.value.first,
    };

/// 同 [downloadConfirmedLookupsForWorks]，但给出任务记下的**全部**可直取身份
/// （首选在前，见 [videoDownloadJobConfirmedLookups]）：一家资料源连不上时，同一部
/// 作品的另一个 id 照样可用（BUG-3073）。身份一致性按首选身份判。
Future<Map<String, List<VideoMetadataLookup>>>
    downloadConfirmedLookupListsForWorks(
  FushiDatabase database,
  List<VideoSourceScrapeWork> works,
) async {
  if (works.isEmpty) return const <String, List<VideoMetadataLookup>>{};
  final Map<String, List<VideoDownloadJobFileRow>> filesByJob =
      <String, List<VideoDownloadJobFileRow>>{};
  for (final VideoDownloadJobFileRow row
      in await database.getImportedVideoDownloadJobFiles()) {
    filesByJob.putIfAbsent(row.jobId, () => <VideoDownloadJobFileRow>[]).add(row);
  }
  if (filesByJob.isEmpty) return const <String, List<VideoMetadataLookup>>{};
  final Set<String> memberPaths = <String>{
    for (final VideoSourceScrapeWork work in works)
      for (final VideoBookRow member in work.members)
        normalizeVideoPath(member.videoPath),
  };
  final Map<String, List<VideoMetadataLookup>> result =
      <String, List<VideoMetadataLookup>>{};
  final Set<String> conflicted = <String>{};
  for (final VideoDownloadJobRow job in await database.getVideoDownloadJobs()) {
    final List<VideoDownloadJobFileRow>? files = filesByJob[job.jobId];
    if (files == null) continue;
    if (!downloadJobImportedVideoPaths(files).any(memberPaths.contains)) {
      continue;
    }
    final List<VideoMetadataLookup> lookups =
        videoDownloadJobConfirmedLookups(job);
    if (lookups.isEmpty) continue;
    final VideoSourceScrapeWork? work = downloadJobWork(job, files, works);
    if (work == null) continue;
    final List<VideoMetadataLookup>? existing = result[work.stableKey];
    if (existing != null && !_sameLookup(existing.first, lookups.first)) {
      conflicted.add(work.stableKey);
    }
    result[work.stableKey] = lookups;
  }
  conflicted.forEach(result.remove);
  return result;
}

bool _sameLookup(VideoMetadataLookup a, VideoMetadataLookup b) =>
    a.provider == b.provider &&
    a.externalId == b.externalId &&
    a.mediaKind == b.mediaKind;
