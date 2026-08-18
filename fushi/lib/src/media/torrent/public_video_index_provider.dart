import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/public_video_index_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';

/// 内置公共索引器的 provider id（设置页开关、停用清单偏好、去重键三处共用）。
const String kApibayResourceProviderId = 'apibay';
const String kKnabenResourceProviderId = 'knaben';

/// apibay 分类：201 Movies / 207 HD Movies / 205 TV shows / 208 HD TV shows。
const List<int> kApibayMovieCategories = <int>[207, 201];
const List<int> kApibayTvCategories = <int>[208, 205];

/// Knaben 分类层级根：3000000 Movies / 2000000 TV。
const int kKnabenMovieCategory = 3000000;
const int kKnabenTvCategory = 2000000;

/// 两家公共索引器共用的候选行。
///
/// 一个 candidate 类而不是两个：它们的 `resolve` 都只是「把磁链交出去」，
/// 差异全在抓取那一段，没有任何理由在这一层再分叉。
class PublicVideoIndexCandidate extends VideoResourceCandidate {
  PublicVideoIndexCandidate({
    required this.torrent,
    required String providerId,
    required String providerInstanceId,
    required int providerPriority,
  }) : super(
          providerId: providerId,
          providerInstanceId: providerInstanceId,
          remoteId: torrent.infoHash,
          title: torrent.title,
          providerPriority: providerPriority,
          infoHash: torrent.infoHash,
          sizeBytes: torrent.sizeBytes,
          seeders: torrent.seeders,
          leechers: torrent.leechers,
          completed: torrent.completed,
          publishedAt: torrent.publishedAt,
          category: torrent.category,
          resolution: torrent.resolution,
          releaseGroup: torrent.releaseGroup,
          detailsUrl: torrent.detailsUrl,
        );

  final PublicVideoIndexTorrent torrent;
}

/// apibay（The Pirate Bay）内置资源索引器：电影 + 剧集，零配置。
///
/// 域：`movie` / `tv`。**刻意不含 `anime`**——动漫由 Nyaa 负责，那里的字幕组
/// 标题/分类远比综合站精确，让综合站也进动漫域只会把 Nyaa 的结果挤下去。
class ApibayVideoResourceProvider implements VideoResourceProvider {
  ApibayVideoResourceProvider({
    required ApibayClient client,
    this.priority = 200,
    bool closesClient = false,
  })  : _client = client,
        _closesClient = closesClient;

  final ApibayClient _client;
  final bool _closesClient;

  @override
  final int priority;

  @override
  String get id => kApibayResourceProviderId;

  @override
  Set<VideoDiscoveryCategory> get categories => const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      };

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final String query = request.effectiveQuery.trim();
    if (query.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        const ExternalProviderFailure(
          providerId: kApibayResourceProviderId,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    try {
      final List<PublicVideoIndexTorrent> torrents = await _client.search(
        query,
        categories:
            request.media?.discoveryCategory == VideoDiscoveryCategory.tv
                ? kApibayTvCategories
                : kApibayMovieCategories,
      );
      return ProviderBatchResult<VideoResourceCandidate>(
        items: deduplicateVideoResources(
          torrents.map(
            (PublicVideoIndexTorrent torrent) => PublicVideoIndexCandidate(
              torrent: torrent,
              providerId: id,
              providerInstanceId: 'apibay.org',
              providerPriority: priority,
            ),
          ),
        ).take(request.limit).toList(),
        successfulProviderCount: 1,
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        ExternalProviderFailure.fromException(
          providerId: id,
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      resolvePublicVideoIndexCandidate(candidate, id);

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// Knaben 内置资源索引器：电影 + 剧集，零配置。域约定同 apibay。
class KnabenVideoResourceProvider implements VideoResourceProvider {
  KnabenVideoResourceProvider({
    required KnabenClient client,
    this.priority = 210,
    bool closesClient = false,
  })  : _client = client,
        _closesClient = closesClient;

  final KnabenClient _client;
  final bool _closesClient;

  @override
  final int priority;

  @override
  String get id => kKnabenResourceProviderId;

  @override
  Set<VideoDiscoveryCategory> get categories => const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      };

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final String query = request.effectiveQuery.trim();
    if (query.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        const ExternalProviderFailure(
          providerId: kKnabenResourceProviderId,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    try {
      final List<PublicVideoIndexTorrent> torrents = await _client.search(
        query,
        categories: <int>[
          request.media?.discoveryCategory == VideoDiscoveryCategory.tv
              ? kKnabenTvCategory
              : kKnabenMovieCategory,
        ],
        limit: request.limit,
      );
      return ProviderBatchResult<VideoResourceCandidate>(
        items: deduplicateVideoResources(
          torrents.map(
            (PublicVideoIndexTorrent torrent) => PublicVideoIndexCandidate(
              torrent: torrent,
              providerId: id,
              providerInstanceId: 'knaben.org',
              providerPriority: priority,
            ),
          ),
        ).take(request.limit).toList(),
        successfulProviderCount: 1,
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        ExternalProviderFailure.fromException(
          providerId: id,
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      resolvePublicVideoIndexCandidate(candidate, id);

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// 候选 → 磁链 payload。两家 provider 共用：`resolve` 的全部内容就是「这条候选
/// 确实是我发出去的」+「把磁链交出去」，没有第二种写法。
TorrentAddPayload resolvePublicVideoIndexCandidate(
  VideoResourceCandidate candidate,
  String providerId,
) {
  if (candidate is! PublicVideoIndexCandidate ||
      candidate.providerId != providerId) {
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: 'resolve',
      kind: ExternalProviderFailureKind.unsupported,
      message: 'candidate belongs to another provider',
    );
  }
  return TorrentMagnetPayload(
    magnetUri: candidate.torrent.magnet,
    torrentId: candidate.torrent.infoHash,
  );
}
