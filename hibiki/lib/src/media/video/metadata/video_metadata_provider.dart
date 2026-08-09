/// MoviePilot 风格的「单主源」视频元数据 provider 契约。
library;

import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';

class VideoMetadataSearchRequest {
  const VideoMetadataSearchRequest({
    required this.title,
    required this.mediaKind,
    this.year,
    this.seasonNumber,
    this.limit = 15,
  });

  final String title;
  final VideoMetadataMediaKind mediaKind;
  final int? year;
  final int? seasonNumber;
  final int limit;
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
}

/// Optional provider capability for work-level online trailers and extras.
abstract interface class VideoMetadataExtrasProvider {
  Future<List<VideoMetadataExtra>> fetchExtras(VideoMetadataLookup lookup);
}

/// Fanart 一类只补图、不参与作品识别的来源。
abstract interface class VideoMetadataImageProvider {
  bool get isAvailable;

  Future<List<VideoMetadataImage>> fetchImages(VideoMetadataWork work);

  void close();
}

class VideoMetadataProviderUnavailable implements Exception {
  const VideoMetadataProviderUnavailable(this.provider, this.reason);

  final VideoMetadataProviderKind provider;
  final String reason;

  @override
  String toString() =>
      'VideoMetadataProviderUnavailable(${provider.name}): $reason';
}
