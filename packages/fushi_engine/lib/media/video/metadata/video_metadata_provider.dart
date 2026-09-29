/// 视频资料源的统一查询、身份和分集能力契约。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

class VideoMetadataSearchRequest {
  const VideoMetadataSearchRequest({
    required this.title,
    required this.mediaKind,
    this.year,
    this.seasonNumber,
    this.limit = 15,
    this.includeAdult = false,
  });

  final String title;
  final VideoMetadataMediaKind mediaKind;
  final int? year;
  final int? seasonNumber;
  final int limit;

  /// 作品已知是成人向（AniDB `restricted` / MAL `Rx`）时让 TMDB 搜索带
  /// `include_adult=true`（Shoko `AutoSearchForShow(includeRestricted:
  /// anime.IsRestricted)`）；TMDB 默认把成人条目从搜索结果里剔掉，不带这个
  /// 参数这类作品永远补不到 TMDB。
  final bool includeAdult;
}

class VideoMetadataLookup {
  const VideoMetadataLookup({
    required this.provider,
    required this.externalId,
    required this.mediaKind,
    this.episodeGroupId,
  });

  final VideoMetadataProviderKind provider;
  final String externalId;
  final VideoMetadataMediaKind mediaKind;

  /// TMDB alternate episode order/group. Other providers ignore this value,
  /// but it stays attached to a confirmed binding and canonical work.
  final String? episodeGroupId;
}

abstract interface class VideoMetadataProvider {
  VideoMetadataProviderKind get providerKind;

  /// 配置是否足以实际访问该来源。不可用的 provider 必须在发网络请求前返回 false。
  bool get isAvailable;

  Future<List<VideoMetadataWork>> search(VideoMetadataSearchRequest request);

  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup);

  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  );

  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  });

  void close();
}

/// 可提供 TMDB alternate episode order/group 的来源能力。
///
/// TMDB 有些长篇作品把所有集压在一个 season 下（例如 Re:Zero），真正的季度
/// 划分只存在 episode group。识别器用本地季号和集数选择 group，随后将 group id
/// 固定到作品绑定，避免每次重扫重新猜测。
abstract interface class VideoMetadataEpisodeGroupProvider {
  Future<VideoMetadataLookup?> resolveEpisodeGroup(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
    int? episodeCount,
  });

  /// 这部剧在资料源上的全部备选排序（TMDB episode groups；Shoko
  /// `TMDB_AlternateOrdering` 整套下载后由用户选 `PreferredAlternateOrderingID`）。
  /// 不按类型过滤——用户选择不受「季」类型限制。非剧集 / 没有 → 空表。
  Future<List<VideoMetadataEpisodeGroupSummary>> listEpisodeGroups(
    VideoMetadataLookup lookup,
  );
}

/// 一条备选排序的摘要（TMDB `/tv/{id}/episode_groups` 的 `results[]`）。
class VideoMetadataEpisodeGroupSummary {
  const VideoMetadataEpisodeGroupSummary({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.groupCount,
    this.episodeCount,
  });

  final String id;
  final String name;

  /// TMDB 排序类型：1 原播出、2 绝对集号、3 DVD、4 数字发行、5 故事线、6 制作、
  /// 7 电视播出（Shoko `AlternateOrderingType` 同值域）。
  final int type;
  final String? description;
  final int? groupCount;
  final int? episodeCount;
}

/// 集级匹配（Shoko `MatchAnidbToTmdbEpisodes`）用的集名多语言能力：资料语言
/// 之外再给每集 en-US 与剧原语的标题（Shoko 用 en-US + 原语比标题）。返回
/// `集号 → 其它语言标题`；不含资料语言那份（调用方已有）。按季按需拉，不进
/// 常规 hydrate。
abstract interface class VideoMetadataEpisodeAliasProvider {
  Future<Map<int, List<String>>> fetchEpisodeTitleAliases(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  });
}

/// 作品关系（前传）能力：Shoko `TmdbSearchService` 沿 Prequel 链回溯到根作品，
/// 用根作品的标题搜 TMDB 剧（一个 TMDB 剧 = 整个系列，cour 标题搜不到）。
abstract interface class VideoMetadataRelationsProvider {
  Future<List<VideoMetadataLookup>> fetchPrequels(VideoMetadataLookup lookup);
}

/// Optional provider capability for work-level online trailers and extras.
abstract interface class VideoMetadataExtrasProvider {
  Future<List<VideoMetadataExtra>> fetchExtras(VideoMetadataLookup lookup);
}

class VideoMetadataProviderUnavailable implements Exception {
  const VideoMetadataProviderUnavailable(this.provider, this.reason);

  final VideoMetadataProviderKind provider;
  final String reason;

  @override
  String toString() =>
      'VideoMetadataProviderUnavailable(${provider.name}): $reason';
}
