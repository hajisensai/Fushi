import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';

/// Search-only adapter for the existing TMDB, AniList, and Bangumi metadata
/// providers. Recommendation feeds remain a separate capability: the metadata
/// contract has no trending/popular endpoint and this adapter does not invent
/// one.
class VideoMetadataSearchDiscoveryProvider implements VideoDiscoveryProvider {
  VideoMetadataSearchDiscoveryProvider({
    required VideoMetadataProvider provider,
    required Iterable<VideoDiscoveryCategory> categories,
    this.priority = 100,
    bool closesProvider = false,
  })  : _provider = provider,
        _closesProvider = closesProvider,
        capabilities = VideoDiscoveryCapabilities(
          categories: categories,
          feeds: const <VideoDiscoveryFeed>{},
          supportsSearch: true,
          supportsPaging: false,
        );

  final VideoMetadataProvider _provider;
  final bool _closesProvider;

  @override
  String get id => _provider.providerKind.name;

  @override
  final int priority;

  @override
  final VideoDiscoveryCapabilities capabilities;

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> discover(
    VideoDiscoveryRequest request,
  ) async =>
      ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'discover',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'metadata provider does not expose discovery feeds',
        ),
      );

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> search(
    VideoDiscoveryRequest request,
  ) async {
    final String query = request.query?.trim() ?? '';
    if (query.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    if (!_provider.isAvailable) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'metadata provider is not configured',
        ),
      );
    }

    final List<VideoMetadataMediaKind> kinds = _requestedKinds(request);
    if (kinds.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
              items: const <VideoDiscoveryItem>[], page: 1, hasMore: false),
        ],
      );
    }
    final List<VideoMetadataWork> works = <VideoMetadataWork>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulSearches = 0;
    for (final VideoMetadataMediaKind kind in kinds) {
      try {
        works.addAll(
          await _provider.search(
            VideoMetadataSearchRequest(
              title: query,
              mediaKind: kind,
              year: request.year,
              limit: request.pageSize.clamp(1, 50),
            ),
          ),
        );
        successfulSearches++;
      } on Object catch (error) {
        failures.add(
          ExternalProviderFailure.fromException(
            providerId: id,
            operation: 'search-${kind.name}',
            error: error,
          ),
        );
      }
    }

    final Map<String, VideoDiscoveryItem> items =
        <String, VideoDiscoveryItem>{};
    for (final VideoMetadataWork work in works) {
      final VideoDiscoveryItem item = VideoDiscoveryItem.fromMetadataWork(
        work: work,
        discoveryCategory: _categoryForWork(request, work),
      );
      items.putIfAbsent(item.reference.canonicalIdentityKey, () => item);
    }
    return ProviderBatchResult<VideoDiscoveryPage>(
      items: successfulSearches == 0
          ? const <VideoDiscoveryPage>[]
          : <VideoDiscoveryPage>[
              VideoDiscoveryPage(
                items: items.values.take(request.pageSize),
                page: 1,
                hasMore: false,
              ),
            ],
      failures: failures,
      successfulProviderCount: successfulSearches == 0 ? 0 : 1,
    );
  }

  List<VideoMetadataMediaKind> _requestedKinds(
    VideoDiscoveryRequest request,
  ) {
    final VideoDiscoveryCategory? requested = request.category;
    if (requested != null && !capabilities.categories.contains(requested)) {
      return const <VideoMetadataMediaKind>[];
    }
    final Set<VideoMetadataMediaKind> kinds = <VideoMetadataMediaKind>{};
    final Iterable<VideoDiscoveryCategory> categories = requested == null
        ? capabilities.categories
        : <VideoDiscoveryCategory>[requested];
    for (final VideoDiscoveryCategory category in categories) {
      switch (category) {
        case VideoDiscoveryCategory.movie:
          kinds.add(VideoMetadataMediaKind.movie);
        case VideoDiscoveryCategory.tv:
          kinds.add(VideoMetadataMediaKind.tv);
        case VideoDiscoveryCategory.anime:
          kinds.addAll(VideoMetadataMediaKind.values);
      }
    }
    return List<VideoMetadataMediaKind>.unmodifiable(kinds);
  }

  VideoDiscoveryCategory _categoryForWork(
    VideoDiscoveryRequest request,
    VideoMetadataWork work,
  ) {
    if (request.category == VideoDiscoveryCategory.anime ||
        (capabilities.categories.length == 1 &&
            capabilities.categories.single == VideoDiscoveryCategory.anime)) {
      return VideoDiscoveryCategory.anime;
    }
    return work.kind == VideoMetadataMediaKind.movie
        ? VideoDiscoveryCategory.movie
        : VideoDiscoveryCategory.tv;
  }

  @override
  void close() {
    if (_closesProvider) _provider.close();
  }
}
