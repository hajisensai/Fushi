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
}) {
  final Map<String, String> ids = <String, String>{
    for (final VideoMetadataId id in metadata.ids)
      if (id.value.trim().isNotEmpty) id.type.trim().toLowerCase(): id.value,
  };
  int? intId(String key) => int.tryParse(ids[key] ?? '');
  final int? anilistId = intId('anilist');
  return VideoMediaReference(
    providerId: metadata.provider.name,
    mediaId: ids[metadata.provider.name] ?? metadata.title,
    mediaKind: metadata.kind,
    discoveryCategory: scrapedDiscoveryCategory(metadata),
    title: metadata.title,
    originalTitle: metadata.originalTitle,
    aliases: metadata.aliases,
    year: metadata.year,
    season: season,
    episode: episode,
    tmdbId: intId('tmdb'),
    imdbId: ids['imdb'],
    tvdbId: intId('tvdb'),
    anilistId: anilistId,
    bangumiId: intId('bangumi'),
    externalIds: ids,
  );
}

/// 刮削元数据 → 发现层分类。
///
/// `VideoMetadataMediaKind` 只有 movie/tv，动画与真人共用同一个值——分类信息在
/// 刮削侧只能从「有没有 AniList id」推：AniList 是动画专库，挂上 AniList id 的
/// 作品就是动画。这不是完美判据（少数真人特摄也被收录），但它决定的只是 Jimaku
/// 的 anime 过滤档，而那一档现在两边都试得到（[JimakuAnimeFilter.either]），
/// 判错的代价只是多一次请求。
VideoDiscoveryCategory scrapedDiscoveryCategory(VideoMetadataWork metadata) {
  final bool hasAnilist = metadata.ids.any(
    (VideoMetadataId id) =>
        id.type.trim().toLowerCase() == 'anilist' && id.value.trim().isNotEmpty,
  );
  if (hasAnilist) return VideoDiscoveryCategory.anime;
  return metadata.kind == VideoMetadataMediaKind.movie
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
