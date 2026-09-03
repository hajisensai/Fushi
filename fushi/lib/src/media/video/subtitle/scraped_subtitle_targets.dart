/// 刮削结论 → 字幕补齐目标的**纯映射**。
///
/// 单独成文件、纯函数，是因为这里正是准确率的分水岭：字幕搜得准不准，取决于
/// 交给 provider 的是「刮削解析出的 AniList/TMDB id + 日文原名 + 真实季集号」，
/// 还是「文件名里的中文译名」。这一步既然是全部价值所在，就该能被单测钉死，而
/// 不是埋在某个 service 的 200 行方法中间。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';

/// 从刮削出的 [metadata] 与本地 [members] 生成待补字幕目标。
///
/// [hasExistingSubtitle] 由调用方按 bookUid 提供（DB 里的 `subtitleSource`）；
/// 磁盘上的 sidecar 由 [VideoSubtitleBackfillService] 自己再查一道。
///
/// 季集号取**本地文件名解析**的结果而不是刮削的顺序：文件名是用户磁盘上的事实，
/// 而合集里可能缺集、含特典、被拖拽重排过（`sortIndex` 不可信，见批量字幕那边同
/// 样的教训）。解析不出集号的成员只在「整个作品就一个文件」（电影/剧场版）时才
/// 生成目标——多集里认不出集号，配上去只能是碰运气。
List<SubtitleBackfillTarget> scrapedSubtitleTargets({
  required List<VideoBookRow> members,
  required VideoMetadataWork metadata,
  required bool Function(String bookUid) hasExistingSubtitle,
}) {
  if (members.isEmpty) return const <SubtitleBackfillTarget>[];
  final bool single = members.length == 1;
  final List<SubtitleBackfillTarget> out = <SubtitleBackfillTarget>[];
  for (final VideoBookRow book in members) {
    if (book.videoPath.trim().isEmpty) continue;
    final VideoNameInfo parsed = parseVideoFilename(p.basename(book.videoPath));
    final int? episode = parsed.episode;
    if (episode == null && !single) continue;
    final int? season = episode == null ? null : (parsed.season ?? 1);
    out.add(SubtitleBackfillTarget(
      bookUid: book.bookUid,
      videoPath: book.videoPath,
      hasExistingSubtitle: hasExistingSubtitle(book.bookUid),
      media: scrapedMediaReference(
        metadata,
        season: season,
        episode: episode,
      ),
      scrapedRuntimeMinutes: _runtimeFor(metadata, season, episode),
      // 「默认下视频语言的字幕」的两个来源：用户对本视频手动指定的内容语言
      // （压过一切），与刮削出的作品原语言。两者都可能为空，那时由 ffprobe 的
      // 音轨 tag 兜底，再没有就不表态——不猜。
      contentLanguage: book.language,
      originalLanguage: metadata.originalLanguage,
    ));
  }
  return out;
}

/// 把刮削元数据折成 provider 认得的规范身份。
///
/// 三件事必须原样带过去，缺一件准确率就塌一层：
/// - **外部 id**（anilist / tmdb / bangumi / imdb / tvdb）：Jimaku 按 anilist_id
///   直查、OpenSubtitles 按 imdb/tmdb 直查，命中率与文本搜不在一个量级；
/// - **originalTitle**（日文原名）：id 没命中时的回退查询词。用中文译名回退等于
///   不回退；
/// - **discoveryCategory**：决定 Jimaku 的 anime 硬过滤走哪一档（BUG-1694）。
VideoMediaReference scrapedMediaReference(
  VideoMetadataWork metadata, {
  int? season,
  int? episode,
}) =>
    identityMediaReference(
      providerId: metadata.provider.name,
      kind: metadata.kind,
      externalIds: _idsOf(metadata),
      title: metadata.title,
      originalTitle: metadata.originalTitle,
      aliases: metadata.aliases,
      year: metadata.year,
      season: season,
      episode: episode,
    );

/// 同一张映射的**去模型化**入口：只吃 `provider → externalId` 与媒体形态。
///
/// 存在的理由是本仓没有「Drift 行 → [VideoMetadataWork]」的反序列化（store 是
/// 只写的），于是每个读库的 UI 只拿得到 `video_metadata_works` 行 +
/// `video_metadata_provider_identities` 行，各自手搓一份 [VideoMediaReference]，
/// 每份都少带几件东西——BUG-2008 里合集字幕面板那份丢了 imdb/tvdb/anidb/year，
/// 还把 [VideoDiscoveryCategory] 写死成 anime，真人剧合集直接踩回 BUG-1694。
/// 手搓一次就漂移一次，所以身份构造只留这一个原语。
///
/// [providerId] 只决定 `mediaId` 取哪个外部 id（取不到时退回 [title]），不参与
/// 检索键的选择：provider 各自按 anilist / tmdb / imdb 取所需。
VideoMediaReference identityMediaReference({
  required String providerId,
  required VideoMetadataMediaKind kind,
  required Map<String, String> externalIds,
  required String title,
  String? originalTitle,
  Iterable<String> aliases = const <String>[],
  int? year,
  int? season,
  int? episode,
}) {
  final Map<String, String> ids = <String, String>{
    for (final MapEntry<String, String> entry in externalIds.entries)
      if (entry.value.trim().isNotEmpty)
        entry.key.trim().toLowerCase(): entry.value.trim(),
  };
  int? intId(String key) => int.tryParse(ids[key] ?? '');
  return VideoMediaReference(
    providerId: providerId,
    mediaId: ids[providerId.trim().toLowerCase()] ?? title,
    mediaKind: kind,
    discoveryCategory: identityDiscoveryCategory(kind: kind, externalIds: ids),
    title: title,
    originalTitle: originalTitle,
    aliases: aliases,
    year: year,
    season: season,
    episode: episode,
    anidbId: intId('anidb'),
    tmdbId: intId('tmdb'),
    imdbId: ids['imdb'],
    tvdbId: intId('tvdb'),
    anilistId: intId('anilist'),
    bangumiId: intId('bangumi'),
    externalIds: ids,
  );
}

/// `VideoMetadataWork.ids` → `provider → externalId`（空值直接丢弃）。
Map<String, String> _idsOf(VideoMetadataWork metadata) => <String, String>{
      for (final VideoMetadataId id in metadata.ids)
        if (id.value.trim().isNotEmpty) id.type.trim().toLowerCase(): id.value,
    };

/// 刮削元数据 → 发现层分类。
///
/// `VideoMetadataMediaKind` 只有 movie/tv，动画与真人共用同一个值——分类信息在
/// 刮削侧优先从「有没有 AniDB id」推；历史数据仍接受 AniList id。两者都是动画
/// 专库，挂上对应 id 的作品视为动画。这不是完美判据，但**刮削过的作品**判据够硬：
/// 动画走 AniDB 主身份、真人走 TMDB，两条链不会互串。
///
/// 注意代价不对称：分类决定 Jimaku 的 `anime` 硬过滤档，而 `anime` / `liveAction`
/// 两档各自**只试一个值**（只有分类为 null 时才走 [JimakuAnimeFilter.either] 依次
/// 试两档）。所以判错不是「多一次请求」，是那一侧一条都搜不到——这正是 BUG-1694。
/// 因此没有刮削结论时宁可不表态（传 null），也不要拿形态硬猜。
VideoDiscoveryCategory scrapedDiscoveryCategory(VideoMetadataWork metadata) =>
    identityDiscoveryCategory(
      kind: metadata.kind,
      externalIds: _idsOf(metadata),
    );

/// 同一判据的去模型化入口（见 [identityMediaReference] 为什么需要它）。
VideoDiscoveryCategory identityDiscoveryCategory({
  required VideoMetadataMediaKind kind,
  required Map<String, String> externalIds,
}) {
  final bool hasAnimeId = externalIds.entries.any(
    (MapEntry<String, String> entry) =>
        const <String>{
          'anidb',
          'anilist',
        }.contains(entry.key.trim().toLowerCase()) &&
        entry.value.trim().isNotEmpty,
  );
  if (hasAnimeId) return VideoDiscoveryCategory.anime;
  return kind == VideoMetadataMediaKind.movie
      ? VideoDiscoveryCategory.movie
      : VideoDiscoveryCategory.tv;
}

/// 该集（或整部电影）的播出时长（分钟）；刮削没给就返回 null。
int? _runtimeFor(VideoMetadataWork metadata, int? season, int? episode) {
  if (season == null || episode == null) return metadata.runtimeMinutes;
  for (final VideoMetadataSeason s in metadata.seasons) {
    if (s.seasonNumber != season) continue;
    for (final VideoMetadataEpisode e in s.episodes) {
      if (e.episodeNumber == episode) {
        return e.runtimeMinutes ?? metadata.runtimeMinutes;
      }
    }
  }
  return metadata.runtimeMinutes;
}
