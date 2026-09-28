import 'package:fushi/src/media/video/metadata/video_metadata_provider_label.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';

/// Search-only adapter for the existing metadata
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
  String get displayName => videoMetadataProviderLabel(_provider.providerKind);

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
            items: const <VideoDiscoveryItem>[],
            page: 1,
            hasMore: false,
          ),
        ],
      );
    }
    final List<List<VideoMetadataWork>> worksByKind =
        <List<VideoMetadataWork>>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulSearches = 0;
    for (final VideoMetadataMediaKind kind in kinds) {
      try {
        worksByKind.add(
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
        // BUG-2430：必须走共享翻译，否则 Jikan 的 429 会被压成 unknown，UI 把
        // 「被限流，等一会儿再搜」显示成「来源暂不可用」。
        failures.add(
          externalFailureFromVideoMetadataError(
            providerId: id,
            operation: 'search-${kind.name}',
            error: error,
          ),
        );
      }
    }

    final Map<String, VideoDiscoveryItem> items =
        <String, VideoDiscoveryItem>{};
    for (final VideoMetadataWork work in _interleave(worksByKind)) {
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

  /// 各类型的搜索各自按来源相关度排好；直接首尾相接会让第一种类型（剧场版）的
  /// 整页模糊命中全排在 TV 正片前面，所以按名次交错。
  static List<VideoMetadataWork> _interleave(
    List<List<VideoMetadataWork>> lists,
  ) {
    final List<VideoMetadataWork> result = <VideoMetadataWork>[];
    for (int index = 0;
        lists.any((List<VideoMetadataWork> list) => index < list.length);
        index++) {
      for (final List<VideoMetadataWork> list in lists) {
        if (index < list.length) result.add(list[index]);
      }
    }
    return result;
  }

  List<VideoMetadataMediaKind> _requestedKinds(VideoDiscoveryRequest request) {
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
          // TV 在前：交错时同名次先给正片，再给剧场版。
          kinds
            ..add(VideoMetadataMediaKind.tv)
            ..add(VideoMetadataMediaKind.movie);
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
