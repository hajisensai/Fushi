import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';

class NyaaVideoResourceProvider implements VideoResourceProvider {
  NyaaVideoResourceProvider({
    required NyaaClient client,
    this.category = '1_0',
    this.filter = '0',
    this.priority = 100,
    bool closesClient = false,
  })  : _client = client,
        _closesClient = closesClient;

  final NyaaClient _client;
  final bool _closesClient;
  final String category;
  final String filter;

  @override
  final int priority;

  @override
  String get id => 'nyaa';

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final List<String> queries = preferredNyaaSearchQueries(request);
    if (queries.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        const ExternalProviderFailure(
          providerId: 'nyaa',
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final List<VideoResourceCandidate> candidates = <VideoResourceCandidate>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    var successfulQueries = 0;
    for (final String query in queries) {
      try {
        final List<NyaaTorrent> torrents = await _client.search(
          query,
          category: category,
          filter: filter,
          page: request.page,
        );
        successfulQueries += 1;
        candidates.addAll(
          torrents.map(
            (NyaaTorrent torrent) => _NyaaResourceCandidate(torrent, priority),
          ),
        );
      } on Object catch (error) {
        failures.add(
          ExternalProviderFailure.fromException(
            providerId: id,
            operation: 'search',
            error: error,
          ),
        );
      }
    }
    if (successfulQueries == 0) {
      return ProviderBatchResult<VideoResourceCandidate>.failure(
        failures.first,
      );
    }
    return ProviderBatchResult<VideoResourceCandidate>(
      items: deduplicateVideoResources(candidates).take(request.limit).toList(),
      failures: failures,
      successfulProviderCount: 1,
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    if (candidate is! _NyaaResourceCandidate) {
      throw const ExternalProviderFailure(
        providerId: 'nyaa',
        operation: 'resolve',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    return TorrentMagnetPayload(
      magnetUri: candidate.torrent.magnet,
      torrentId: candidate.torrent.infoHash.toLowerCase(),
    );
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// Nyaa 标题命中以 AniList 罗马字和日文原名最稳定。发现页展示标题
/// 可能已本地化，因此只把它放在罗马字/日文后作最后兜底。
List<String> preferredNyaaSearchQueries(VideoResourceSearchRequest request) {
  final VideoMediaReference? media = request.media;
  final List<String> candidates = <String>[
    if (request.query case final String query) query,
    if (media != null) ...media.aliases,
    if (media?.originalTitle case final String original) original,
    if (media != null) media.title,
    request.effectiveQuery,
  ];
  final List<String> romanized = <String>[];
  final List<String> japanese = <String>[];
  final List<String> fallback = <String>[];
  final Set<String> seen = <String>{};
  for (final String candidate in candidates) {
    final String value = candidate.trim();
    final String key = value.toLowerCase();
    if (value.isEmpty || !seen.add(key)) continue;
    if (RegExp(r'[A-Za-z]').hasMatch(value) &&
        !RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(value)) {
      romanized.add(value);
    } else if (RegExp(r'[\u3040-\u30ff]').hasMatch(value) ||
        value == media?.originalTitle?.trim()) {
      japanese.add(value);
    } else {
      fallback.add(value);
    }
  }
  return <String>[
    ...romanized.take(1),
    ...japanese.take(1),
    if (romanized.isEmpty && japanese.isEmpty) ...fallback.take(1),
  ];
}

class _NyaaResourceCandidate extends VideoResourceCandidate {
  _NyaaResourceCandidate(this.torrent, int providerPriority)
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa.si',
          remoteId: torrent.infoHash.toLowerCase(),
          title: torrent.title,
          providerPriority: providerPriority,
          infoHash: torrent.infoHash.toLowerCase(),
          sizeBytes: torrent.sizeBytes,
          seeders: torrent.seeders,
          leechers: torrent.leechers,
          completed: torrent.downloads,
          publishedAt: torrent.pubDate,
          category: torrent.categoryId,
          resolution: torrent.resolution,
          releaseGroup: torrent.releaseGroup,
          trusted: torrent.trusted,
          detailsUrl: torrent.pageUrl,
        );

  final NyaaTorrent torrent;
}
