import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';

class VideoResourceSearchRequest {
  const VideoResourceSearchRequest({
    this.media,
    this.query,
    this.season,
    this.episode,
    this.page = 1,
    this.limit = 100,
  })  : assert(page > 0),
        assert(limit > 0);

  final VideoMediaReference? media;
  final String? query;
  final int? season;
  final int? episode;
  final int page;
  final int limit;

  String get effectiveQuery => query?.trim().isNotEmpty == true
      ? query!.trim()
      : media?.title.trim() ?? '';

  int? get effectiveSeason => season ?? media?.season;
  int? get effectiveEpisode => episode ?? media?.episode;
}

abstract class VideoResourceCandidate {
  VideoResourceCandidate({
    required this.providerId,
    required this.providerInstanceId,
    required this.remoteId,
    required this.title,
    required this.providerPriority,
    this.infoHash,
    this.sizeBytes,
    this.seeders = 0,
    this.leechers = 0,
    this.completed = 0,
    this.publishedAt,
    this.category,
    this.resolution,
    this.releaseGroup,
    this.trusted = false,
    this.detailsUrl,
  });

  final String providerId;
  final String providerInstanceId;
  final String remoteId;
  final String title;
  final int providerPriority;
  final String? infoHash;
  final int? sizeBytes;
  final int seeders;
  final int leechers;
  final int completed;
  final DateTime? publishedAt;
  final String? category;
  final String? resolution;
  final String? releaseGroup;
  final bool trusted;
  final String? detailsUrl;

  /// Cross-indexer dedupe uses the info hash; provider-local identity is a
  /// safe fallback when an indexer does not expose one.
  String get identityKey {
    final String hash = infoHash?.trim().toLowerCase() ?? '';
    if (RegExp(r'^[0-9a-f]{40}$').hasMatch(hash) ||
        RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      return 'torrent:$hash';
    }
    return '$providerId:$providerInstanceId:$remoteId';
  }
}

abstract interface class VideoResourceProvider {
  String get id;

  /// Lower values run first and win duplicate candidates.
  int get priority;

  /// 本 provider 参与哪些视频域。**空集 = 不限域**（用户自配的 Torznab 索引器
  /// 就是这种：搜什么由他自己填的分类决定，app 无权替他裁）。
  ///
  /// 这里之前不存在——域门控是 `VideoResourceRegistry` 里一行写死的 id 白名单
  /// （`provider.id == 'torznab' || (anime && provider.id == 'nyaa')`）。每加一个
  /// 内置源就得回去改那行 if，而 provider 自己对「我该在哪个域出现」一无所知。
  /// 把它变成 provider 自报的能力，registry 那边的特殊情况就整个消失了。
  Set<VideoDiscoveryCategory> get categories;

  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  );

  /// Resolves a selected candidate to a magnet or validated metainfo payload.
  /// Provider credentials and temporary URLs must not escape through payloads.
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate);

  void close();
}

List<VideoResourceCandidate> deduplicateVideoResources(
  Iterable<VideoResourceCandidate> candidates,
) {
  final Map<String, VideoResourceCandidate> best =
      <String, VideoResourceCandidate>{};
  for (final VideoResourceCandidate candidate in candidates) {
    final VideoResourceCandidate? existing = best[candidate.identityKey];
    if (existing == null ||
        candidate.providerPriority < existing.providerPriority ||
        (candidate.providerPriority == existing.providerPriority &&
            candidate.seeders > existing.seeders)) {
      best[candidate.identityKey] = candidate;
    }
  }
  final List<VideoResourceCandidate> result = best.values.toList();
  result.sort((VideoResourceCandidate a, VideoResourceCandidate b) {
    final int byPriority = a.providerPriority.compareTo(b.providerPriority);
    return byPriority != 0 ? byPriority : b.seeders.compareTo(a.seeders);
  });
  return List<VideoResourceCandidate>.unmodifiable(result);
}

/// provider 是否参与某个域的查询。
///
/// [category] 为 null = 请求没带身份（纯关键词搜索）：此时只有不限域的 provider
/// 参与，与 id 白名单时代的行为逐字一致（那时 `anime` 为 false，Nyaa 同样不进）。
bool videoResourceProviderApplies(
  VideoResourceProvider provider,
  VideoDiscoveryCategory? category,
) =>
    provider.categories.isEmpty ||
    (category != null && provider.categories.contains(category));
