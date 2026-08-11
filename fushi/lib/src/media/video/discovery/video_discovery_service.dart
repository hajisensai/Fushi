library;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_adapters.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/discovery/video_metadata_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/anilist_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/bangumi_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/scraper/title_normalizer.dart';

/// 发现页的生产聚合服务。
///
/// 每个来源独立返回成功或脱敏失败；聚合层只在所有可用来源均失败时产生全失败，
/// 单来源故障不会清空其他来源的数据。
class VideoDiscoveryService {
  VideoDiscoveryService({
    required Iterable<VideoDiscoveryProvider> providers,
    Iterable<VideoMetadataProvider> metadataProviders =
        const <VideoMetadataProvider>[],
    bool closesProviders = false,
  })  : _providers = List<VideoDiscoveryProvider>.unmodifiable(
          providers.toList()
            ..sort((VideoDiscoveryProvider a, VideoDiscoveryProvider b) =>
                a.priority.compareTo(b.priority)),
        ),
        _metadataProviders = <VideoMetadataProviderKind, VideoMetadataProvider>{
          for (final VideoMetadataProvider provider in metadataProviders)
            provider.providerKind: provider,
        },
        _closesProviders = closesProviders;

  factory VideoDiscoveryService.production(
    VideoSourceScrapeGlobalConfig config,
  ) {
    final TmdbVideoMetadataProvider tmdb = TmdbVideoMetadataProvider(
      apiKey: config.tmdbApiKey,
      language: config.locale,
    );
    final AniListVideoMetadataProvider anilist = AniListVideoMetadataProvider();
    final BangumiVideoMetadataProvider bangumi = BangumiVideoMetadataProvider(
      accessToken: config.bangumiToken,
    );
    return VideoDiscoveryService(
      providers: <VideoDiscoveryProvider>[
        AniListVideoDiscoveryProvider(),
        TmdbVideoDiscoveryProvider(
          apiKey: config.tmdbApiKey,
          language: config.locale,
        ),
        VideoMetadataSearchDiscoveryProvider(
          provider: bangumi,
          categories: const <VideoDiscoveryCategory>{
            VideoDiscoveryCategory.anime,
          },
          priority: 30,
        ),
      ],
      metadataProviders: <VideoMetadataProvider>[tmdb, anilist, bangumi],
      closesProviders: true,
    );
  }

  final List<VideoDiscoveryProvider> _providers;
  final Map<VideoMetadataProviderKind, VideoMetadataProvider>
      _metadataProviders;
  final bool _closesProviders;
  bool _closed = false;

  Future<ProviderBatchResult<VideoDiscoveryPage>> load(
    VideoDiscoveryRequest request,
  ) async {
    if (_closed) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        const ExternalProviderFailure(
          providerId: 'discovery',
          operation: 'load',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'discovery service is closed',
        ),
      );
    }
    final List<VideoDiscoveryProvider> selected = _providers
        .where((VideoDiscoveryProvider provider) =>
            _supportsRequest(provider, request))
        .toList(growable: false);
    if (selected.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
            items: const <VideoDiscoveryItem>[],
            page: request.page,
            hasMore: false,
          ),
        ],
        successfulProviderCount: 0,
      );
    }

    final List<_ProviderResponse> responses = await Future.wait(
      <Future<_ProviderResponse>>[
        for (final VideoDiscoveryProvider provider in selected)
          _invokeWindow(provider, request),
      ],
    );
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulProviders = 0;
    bool hasMore = false;
    for (final _ProviderResponse response in responses) {
      failures.addAll(response.result.failures);
      successfulProviders += response.result.successfulProviderCount;
      hasMore = hasMore || response.hasMore;
    }

    final List<VideoDiscoveryItem> interleaved = _roundRobin(
      <List<VideoDiscoveryItem>>[
        for (final _ProviderResponse response in responses)
          _prepareProviderItems(response, request),
      ],
    );
    final List<VideoDiscoveryItem> mergedWindow = mergeVideoDiscoveryItems(
      interleaved,
      request: request,
    );
    final int pageOffset = (request.page - 1) * request.pageSize;
    final int pageEnd = pageOffset + request.pageSize;
    final List<VideoDiscoveryItem> pageItems = mergedWindow
        .skip(pageOffset)
        .take(request.pageSize)
        .toList(growable: false);
    hasMore = hasMore || mergedWindow.length > pageEnd;
    return ProviderBatchResult<VideoDiscoveryPage>(
      items: successfulProviders == 0
          ? const <VideoDiscoveryPage>[]
          : <VideoDiscoveryPage>[
              VideoDiscoveryPage(
                items: pageItems,
                page: request.page,
                hasMore: hasMore,
              ),
            ],
      failures: _deduplicateFailures(failures),
      successfulProviderCount: successfulProviders,
    );
  }

  List<VideoDiscoveryItem> _prepareProviderItems(
    _ProviderResponse response,
    VideoDiscoveryRequest request,
  ) {
    final List<VideoDiscoveryItem> items = <VideoDiscoveryItem>[
      for (final VideoDiscoveryPage page in response.pages) ...page.items,
    ];
    if (request.isSearch) {
      items.removeWhere(
        (VideoDiscoveryItem item) => !_matchesSearchFilters(item, request),
      );
    }
    // The metadata-search adapter cannot push sort into Bangumi. Its work
    // summaries still carry rating, vote count, and premiere date, so order
    // that source by the requested verifiable field before round-robin merge.
    if (response.provider.id.trim().toLowerCase() == 'bangumi') {
      _sortMetadataSearchItems(items, request.sort);
    }
    return items;
  }

  /// 按发现项的主身份读取完整详情。该入口不重新模糊搜索，因此后续精确刮削可继续
  /// 使用同一个 confirmed lookup。
  Future<VideoMetadataWork?> loadDetails(VideoDiscoveryItem item) async {
    if (_closed) return item.metadataWork;
    final List<VideoMetadataWork> works = <VideoMetadataWork>[
      for (final VideoMetadataWork? work in await Future.wait(
        <Future<VideoMetadataWork?>>[
          for (final VideoMetadataLookup lookup in _detailLookups(item))
            _fetchDetails(lookup),
        ],
      ))
        if (work != null) work,
    ];
    if (works.isEmpty) return item.metadataWork;
    final bool anime =
        item.reference.discoveryCategory == VideoDiscoveryCategory.anime;
    works.sort((VideoMetadataWork a, VideoMetadataWork b) => _primaryRank(
          a.provider.name,
          anime: anime,
        ).compareTo(_primaryRank(b.provider.name, anime: anime)));
    VideoMetadataWork merged = works.first;
    for (final VideoMetadataWork supplement in works.skip(1)) {
      merged = supplement.provider == VideoMetadataProviderKind.tmdb
          ? supplementVideoMetadataWithTmdb(merged, supplement)
          : _supplementDetails(merged, supplement);
    }
    return merged;
  }

  List<VideoMetadataLookup> _detailLookups(VideoDiscoveryItem item) {
    final VideoMediaReference reference = item.reference;
    final Map<VideoMetadataProviderKind, VideoMetadataLookup> lookups =
        <VideoMetadataProviderKind, VideoMetadataLookup>{};
    final VideoMetadataLookup? confirmed = item.confirmedLookup;
    if (confirmed != null) lookups[confirmed.provider] = confirmed;
    void add(VideoMetadataProviderKind provider, Object? id) {
      final String value = id?.toString().trim() ?? '';
      if (value.isEmpty) return;
      lookups.putIfAbsent(
        provider,
        () => VideoMetadataLookup(
          provider: provider,
          externalId: value,
          mediaKind: reference.mediaKind,
        ),
      );
    }

    add(VideoMetadataProviderKind.anilist, reference.anilistId);
    add(VideoMetadataProviderKind.bangumi, reference.bangumiId);
    add(VideoMetadataProviderKind.tmdb, reference.tmdbId);
    return lookups.values.toList(growable: false);
  }

  Future<VideoMetadataWork?> _fetchDetails(
    VideoMetadataLookup lookup,
  ) async {
    final VideoMetadataProvider? provider = _metadataProviders[lookup.provider];
    if (provider == null || !provider.isAvailable) return null;
    try {
      return await provider.fetchWork(lookup);
    } on Object {
      // 详情补充是加法；一个补源失败不能抹掉主源或发现摘要。
      return null;
    }
  }

  bool _supportsRequest(
    VideoDiscoveryProvider provider,
    VideoDiscoveryRequest request,
  ) {
    final VideoDiscoveryCapabilities capabilities = provider.capabilities;
    final VideoDiscoveryCategory? category = request.category;
    if (category != null && !capabilities.categories.contains(category)) {
      return false;
    }
    if (request.isSearch) {
      if (!capabilities.supportsSearch) return false;
      return true;
    }
    return capabilities.feeds.contains(request.feed);
  }

  Future<_ProviderResponse> _invoke(
    VideoDiscoveryProvider provider,
    VideoDiscoveryRequest request,
  ) async {
    try {
      final ProviderBatchResult<VideoDiscoveryPage> result = request.isSearch
          ? await provider.search(request)
          : await provider.discover(request);
      return _ProviderResponse(provider: provider, result: result);
    } on Object catch (error) {
      return _ProviderResponse(
        provider: provider,
        result: ProviderBatchResult<VideoDiscoveryPage>.failure(
          ExternalProviderFailure.fromException(
            providerId: provider.id,
            operation: request.isSearch ? 'search' : 'discover',
            error: error,
          ),
        ),
      );
    }
  }

  /// Rebuilds the provider's cumulative prefix before slicing the aggregate
  /// page. Fetching only provider page N would permanently discard each
  /// provider's unconsumed page N-1 tail after round-robin merge/dedup.
  Future<_ProviderResponse> _invokeWindow(
    VideoDiscoveryProvider provider,
    VideoDiscoveryRequest request,
  ) async {
    final int lastProviderPage =
        provider.capabilities.supportsPaging ? request.page : 1;
    final List<VideoDiscoveryPage> pages = <VideoDiscoveryPage>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    bool succeeded = false;
    bool hasMore = false;
    for (int page = 1; page <= lastProviderPage; page++) {
      final _ProviderResponse response = await _invoke(
        provider,
        _requestAtPage(request, page),
      );
      failures.addAll(response.result.failures);
      if (response.result.successfulProviderCount > 0) succeeded = true;
      pages.addAll(response.pages);
      final bool responseHasMore = response.pages.any(
        (VideoDiscoveryPage providerPage) => providerPage.hasMore,
      );
      if (response.result.successfulProviderCount == 0) break;
      hasMore = responseHasMore;
      if (!hasMore) break;
    }
    return _ProviderResponse(
      provider: provider,
      result: ProviderBatchResult<VideoDiscoveryPage>(
        items: pages,
        failures: failures,
        successfulProviderCount: succeeded ? 1 : 0,
      ),
      hasMore: hasMore,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_closesProviders) return;
    for (final VideoDiscoveryProvider provider in _providers) {
      provider.close();
    }
    for (final VideoMetadataProvider provider in _metadataProviders.values) {
      provider.close();
    }
  }
}

/// 跨来源身份合并。强 ID 严格优先：同一命名空间取值冲突直接否决，取值相同直接
/// 合并；只有在双方没有任何共享 ID 时，才退到「聚合媒体类型不冲突 + 规范化标题
/// 相交 + 非空年份相同」的弱匹配。AniList/Bangumi 会把部分单集 ONA 标成 TV，而
/// TMDB 将同一作品标成电影；搜索摘要不保证携带集数，集数缺失时聚合类型判为未知，
/// 未知与任何类型都不算冲突（见 [_aggregationKind]）。
List<VideoDiscoveryItem> mergeVideoDiscoveryItems(
  Iterable<VideoDiscoveryItem> items, {
  required VideoDiscoveryRequest request,
}) {
  final List<_MergedDiscoveryItem> groups = <_MergedDiscoveryItem>[];
  for (final VideoDiscoveryItem item in items) {
    _MergedDiscoveryItem? match;
    for (final _MergedDiscoveryItem group in groups) {
      if (group.canMerge(item)) {
        match = group;
        break;
      }
    }
    if (match == null) {
      groups.add(_MergedDiscoveryItem(item));
    } else {
      match.add(item);
    }
  }
  final List<VideoDiscoveryItem> merged = <VideoDiscoveryItem>[
    for (final _MergedDiscoveryItem group in groups) group.build(),
  ];
  if (request.sort == VideoDiscoverySort.rating) {
    merged.sort((VideoDiscoveryItem a, VideoDiscoveryItem b) =>
        (b.score ?? -1).compareTo(a.score ?? -1));
  } else if (request.sort == VideoDiscoverySort.releaseDate) {
    merged.sort((VideoDiscoveryItem a, VideoDiscoveryItem b) =>
        (b.releaseDate ?? '').compareTo(a.releaseDate ?? ''));
  }
  return List<VideoDiscoveryItem>.unmodifiable(merged);
}

class _MergedDiscoveryItem {
  _MergedDiscoveryItem(VideoDiscoveryItem item)
      : _items = <VideoDiscoveryItem>[item];

  final List<VideoDiscoveryItem> _items;

  /// 按证据强度从强到弱判断：
  /// 1. 任一共同命名空间取值冲突 -> 否决（强 ID 说「不是同一个作品」）。
  /// 2. 任一共同命名空间取值相同 -> 合并（强 ID 说「就是同一个作品」）。此时
  ///    不再过任何基于可选字段的启发式闸门 —— 集数、时长这类字段各 adapter
  ///    填充不对称，没有资格推翻已经对上的 ID。
  /// 3. 没有共享 ID 时才退到弱匹配：聚合媒体类型不冲突 + 非空年份相同 +
  ///    规范化标题相交。
  bool canMerge(VideoDiscoveryItem candidate) {
    final Map<String, String> right = _strongIdentities(candidate.reference);
    final List<Map<String, String>> lefts = <Map<String, String>>[
      for (final VideoDiscoveryItem existing in _items)
        _strongIdentities(existing.reference),
    ];
    for (final Map<String, String> left in lefts) {
      if (_hasNamespaceConflict(left, right)) return false;
    }
    for (final Map<String, String> left in lefts) {
      if (left.keys.any(
        (String namespace) => right[namespace] == left[namespace],
      )) {
        return true;
      }
    }
    for (final VideoDiscoveryItem existing in _items) {
      if (_conflictingAggregationKinds(existing, candidate)) return false;
    }
    for (final VideoDiscoveryItem existing in _items) {
      final int? leftYear = existing.reference.year;
      final int? rightYear = candidate.reference.year;
      if (leftYear == null || rightYear == null || leftYear != rightYear) {
        continue;
      }
      final Set<String> leftTitles = _normalizedTitles(existing);
      final Set<String> rightTitles = _normalizedTitles(candidate);
      if (leftTitles.any(rightTitles.contains)) return true;
    }
    return false;
  }

  void add(VideoDiscoveryItem item) => _items.add(item);

  VideoDiscoveryItem build() {
    final bool anime = _items.any(
      (VideoDiscoveryItem item) =>
          item.reference.discoveryCategory == VideoDiscoveryCategory.anime,
    );
    // 组内只要有一条被判定为电影身份，整组就按电影排序（不依赖 _items 的顺序）。
    final bool movieAggregation = _items.any(
      (VideoDiscoveryItem item) =>
          _aggregationKind(item) == VideoMetadataMediaKind.movie,
    );
    final List<VideoDiscoveryItem> ranked = List<VideoDiscoveryItem>.of(_items)
      ..sort((VideoDiscoveryItem a, VideoDiscoveryItem b) {
        // When an anime provider calls a single long-form work TV/ONA while a
        // movie database calls it a movie, keep the movie identity as primary.
        // This makes the merged card open/scrape as a movie, matching the
        // MoviePilot-style result users see, while retaining the anime ids.
        if (movieAggregation) {
          const VideoMetadataMediaKind movie = VideoMetadataMediaKind.movie;
          final int kindRank = (a.reference.mediaKind == movie ? 0 : 1)
              .compareTo(b.reference.mediaKind == movie ? 0 : 1);
          if (kindRank != 0) return kindRank;
        }
        return _primaryRank(a.reference.providerId, anime: anime)
            .compareTo(_primaryRank(b.reference.providerId, anime: anime));
      });
    final VideoDiscoveryItem primary = ranked.first;
    final Map<String, String> externalIds = <String, String>{};
    final List<VideoMetadataId> metadataIds = <VideoMetadataId>[];
    final Set<String> metadataIdKeys = <String>{};
    final Set<String> aliases = <String>{};
    for (final VideoDiscoveryItem item in ranked) {
      final VideoMediaReference reference = item.reference;
      externalIds.addAll(reference.externalIds);
      void addExternal(String namespace, Object? value) {
        final String normalized = value?.toString().trim() ?? '';
        if (normalized.isNotEmpty) {
          externalIds.putIfAbsent(
            namespace,
            () => normalized,
          );
        }
      }

      addExternal('tmdb', reference.tmdbId);
      addExternal('imdb', reference.imdbId);
      addExternal('tvdb', reference.tvdbId);
      addExternal('anilist', reference.anilistId);
      addExternal('bangumi', reference.bangumiId);
      aliases.add(reference.title);
      if (reference.originalTitle case final String original) {
        aliases.add(original);
      }
      aliases.addAll(reference.aliases);
      for (final VideoMetadataId id
          in item.metadataWork?.ids ?? const <VideoMetadataId>[]) {
        final String key = '${id.type.toLowerCase()}:${id.value}';
        if (metadataIdKeys.add(key)) metadataIds.add(id);
      }
      aliases.addAll(item.metadataWork?.aliases ?? const <String>[]);
    }
    final VideoMetadataWork? primaryWork = primary.metadataWork;
    final VideoMetadataWork? mergedWork = primaryWork?.copyWith(
      aliases: aliases
          .where((String value) => value != primary.reference.title)
          .toList(growable: false),
      ids: metadataIds,
      genres: _uniqueStrings(
        ranked.expand((VideoDiscoveryItem item) => item.genres),
      ),
    );
    final VideoMediaReference reference = VideoMediaReference(
      providerId: primary.reference.providerId,
      mediaId: primary.reference.mediaId,
      mediaKind: primary.reference.mediaKind,
      discoveryCategory: anime
          ? VideoDiscoveryCategory.anime
          : primary.reference.discoveryCategory,
      title: primary.reference.title,
      originalTitle: primary.reference.originalTitle ??
          _firstNonEmpty(
            ranked.map(
              (VideoDiscoveryItem item) => item.reference.originalTitle,
            ),
          ),
      aliases: aliases
          .where((String value) => value != primary.reference.title)
          .toList(growable: false),
      year: primary.reference.year ??
          _firstValue(
              ranked.map((VideoDiscoveryItem item) => item.reference.year)),
      season: primary.reference.season,
      episode: primary.reference.episode,
      tmdbId: primary.reference.tmdbId ?? _parseId(externalIds['tmdb']),
      imdbId: primary.reference.imdbId ?? externalIds['imdb'],
      tvdbId: primary.reference.tvdbId ?? _parseId(externalIds['tvdb']),
      anilistId:
          primary.reference.anilistId ?? _parseId(externalIds['anilist']),
      bangumiId:
          primary.reference.bangumiId ?? _parseId(externalIds['bangumi']),
      externalIds: externalIds,
    );
    return VideoDiscoveryItem(
      reference: reference,
      overview: primary.overview ??
          _firstNonEmpty(
              ranked.map((VideoDiscoveryItem item) => item.overview)),
      posterUrl: primary.posterUrl ??
          _firstNonEmpty(
            ranked.map((VideoDiscoveryItem item) => item.posterUrl),
          ),
      backdropUrl: primary.backdropUrl ??
          _firstNonEmpty(
            ranked.map((VideoDiscoveryItem item) => item.backdropUrl),
          ),
      score: primary.score ??
          _firstValue(ranked.map((VideoDiscoveryItem item) => item.score)),
      releaseDate: primary.releaseDate ??
          _firstNonEmpty(
            ranked.map((VideoDiscoveryItem item) => item.releaseDate),
          ),
      genres: _uniqueStrings(
        ranked.expand((VideoDiscoveryItem item) => item.genres),
      ),
      metadataWork: mergedWork,
      confirmedLookup: primary.confirmedLookup,
    );
  }
}

/// 条目在聚合层的媒体类型；`null` 表示**未知**。
///
/// AniList/Bangumi 会把单集 ONA/OVA 标成 TV，TMDB 把同一作品标成电影，只有拿到
/// 集数才能判定谁对。而集数是可选字段、各 adapter 填充不对称（搜索摘要普遍不带
/// 集数），所以集数缺失时必须承认「不知道」，不能默认成 TV —— 默认成 TV 会把本该
/// 合并的单集作品重新拆成两张卡（BUG-1531 的反面）。未知与任何类型都不算冲突。
VideoMetadataMediaKind? _aggregationKind(VideoDiscoveryItem item) {
  if (item.reference.mediaKind == VideoMetadataMediaKind.movie) {
    return VideoMetadataMediaKind.movie;
  }
  if (item.reference.discoveryCategory == VideoDiscoveryCategory.anime) {
    final int? episodeCount = item.metadataWork?.episodeCount;
    if (episodeCount == null) return null;
    if (episodeCount == 1) return VideoMetadataMediaKind.movie;
  }
  return item.reference.mediaKind;
}

/// 只有双方聚合类型都已知且不同才算冲突；任一侧未知都不足以否决弱匹配。
bool _conflictingAggregationKinds(
  VideoDiscoveryItem left,
  VideoDiscoveryItem right,
) {
  final VideoMetadataMediaKind? leftKind = _aggregationKind(left);
  final VideoMetadataMediaKind? rightKind = _aggregationKind(right);
  if (leftKind == null || rightKind == null) return false;
  return leftKind != rightKind;
}

Map<String, String> _strongIdentities(VideoMediaReference reference) {
  final Map<String, String> result = <String, String>{};
  void add(String namespace, Object? raw) {
    final String value = raw?.toString().trim().toLowerCase() ?? '';
    if (value.isNotEmpty) result[namespace] = value;
  }

  add('imdb', reference.imdbId);
  add('tmdb-${reference.mediaKind.name}', reference.tmdbId);
  add('tvdb', reference.tvdbId);
  add('anilist', reference.anilistId);
  add('bangumi', reference.bangumiId);
  for (final MapEntry<String, String> entry in reference.externalIds.entries) {
    final String rawNamespace = entry.key.trim().toLowerCase();
    final String namespace = rawNamespace == 'tmdb'
        ? 'tmdb-${reference.mediaKind.name}'
        : rawNamespace;
    add(namespace, entry.value);
  }
  add(
    '${reference.providerId.trim().toLowerCase()}-${reference.mediaKind.name}',
    reference.mediaId,
  );
  return result;
}

bool _hasNamespaceConflict(
  Map<String, String> left,
  Map<String, String> right,
) {
  for (final String namespace in left.keys) {
    final String? other = right[namespace];
    if (other != null && other != left[namespace]) return true;
  }
  return false;
}

Set<String> _normalizedTitles(VideoDiscoveryItem item) => <String>{
      item.reference.title,
      if (item.reference.originalTitle case final String original) original,
      ...?item.metadataWork?.aliases,
    }
        .map(TitleNormalizer.normalize)
        .where((String value) => value.isNotEmpty)
        .toSet();

int _primaryRank(String providerId, {required bool anime}) {
  final String provider = providerId.trim().toLowerCase();
  if (anime) {
    return switch (provider) {
      'anilist' => 0,
      'bangumi' => 1,
      'tmdb' => 2,
      _ => 10,
    };
  }
  return switch (provider) {
    'tmdb' => 0,
    'bangumi' => 1,
    'anilist' => 2,
    _ => 10,
  };
}

VideoMetadataWork _supplementDetails(
  VideoMetadataWork primary,
  VideoMetadataWork supplement,
) {
  final Map<String, VideoMetadataId> ids = <String, VideoMetadataId>{};
  for (final VideoMetadataId id in <VideoMetadataId>[
    ...primary.ids,
    ...supplement.ids,
  ]) {
    ids.putIfAbsent('${id.type.toLowerCase()}:${id.value}', () => id);
  }
  final Map<String, VideoMetadataCredit> credits =
      <String, VideoMetadataCredit>{};
  for (final VideoMetadataCredit credit in <VideoMetadataCredit>[
    ...primary.credits,
    ...supplement.credits,
  ]) {
    final VideoMetadataPerson person = credit.person;
    final String personKey = person.id ?? person.name.toLowerCase();
    final String characterKey =
        credit.character?.id ?? credit.character?.name.toLowerCase() ?? '';
    credits.putIfAbsent(
      '${credit.kind.name}:$personKey:$characterKey',
      () => credit,
    );
  }
  final Map<String, VideoMetadataImage> images = <String, VideoMetadataImage>{};
  for (final VideoMetadataImage image in <VideoMetadataImage>[
    ...primary.images,
    ...supplement.images,
  ]) {
    images.putIfAbsent('${image.kind.name}:${image.url}', () => image);
  }
  return primary.copyWith(
    originalTitle: primary.originalTitle ?? supplement.originalTitle,
    tagline: primary.tagline ?? supplement.tagline,
    aliases: _uniqueStrings(<String>[
      ...primary.aliases,
      supplement.title,
      if (supplement.originalTitle case final String original) original,
      ...supplement.aliases,
    ]),
    year: primary.year ?? supplement.year,
    premiered: primary.premiered ?? supplement.premiered,
    endDate: primary.endDate ?? supplement.endDate,
    plot: primary.plot ?? supplement.plot,
    rating: primary.rating ?? supplement.rating,
    ratingVotes: primary.ratingVotes ?? supplement.ratingVotes,
    runtimeMinutes: primary.runtimeMinutes ?? supplement.runtimeMinutes,
    contentRating: primary.contentRating ?? supplement.contentRating,
    status: primary.status ?? supplement.status,
    originalLanguage: primary.originalLanguage ?? supplement.originalLanguage,
    homepage: primary.homepage ?? supplement.homepage,
    seasonCount: primary.seasonCount ?? supplement.seasonCount,
    episodeCount: primary.episodeCount ?? supplement.episodeCount,
    genres: _uniqueStrings(<String>[
      ...primary.genres,
      ...supplement.genres,
    ]),
    studios: _uniqueStrings(<String>[
      ...primary.studios,
      ...supplement.studios,
    ]),
    countries: _uniqueStrings(<String>[
      ...primary.countries,
      ...supplement.countries,
    ]),
    keywords: _uniqueStrings(<String>[
      ...primary.keywords,
      ...supplement.keywords,
    ]),
    ids: ids.values.toList(growable: false),
    credits: credits.values.toList(growable: false),
    images: images.values.toList(growable: false),
    seasons: primary.seasons.isEmpty ? supplement.seasons : primary.seasons,
    extras: primary.extras.isEmpty ? supplement.extras : primary.extras,
  );
}

List<VideoDiscoveryItem> _roundRobin(List<List<VideoDiscoveryItem>> sources) {
  final List<VideoDiscoveryItem> result = <VideoDiscoveryItem>[];
  int index = 0;
  while (
      sources.any((List<VideoDiscoveryItem> source) => index < source.length)) {
    for (final List<VideoDiscoveryItem> source in sources) {
      if (index < source.length) result.add(source[index]);
    }
    index++;
  }
  return result;
}

bool _matchesSearchFilters(
  VideoDiscoveryItem item,
  VideoDiscoveryRequest request,
) {
  if (request.year != null && item.reference.year != request.year) {
    return false;
  }
  final String requestedGenre = _canonicalDiscoveryGenre(request.genre);
  if (requestedGenre.isNotEmpty &&
      !item.genres.map(_canonicalDiscoveryGenre).contains(requestedGenre)) {
    return false;
  }
  final String requestedRegion = _canonicalRegion(request.region);
  if (requestedRegion.isNotEmpty) {
    final Iterable<String> countries =
        item.metadataWork?.countries ?? const <String>[];
    if (!countries.map(_canonicalRegion).contains(requestedRegion)) {
      return false;
    }
  }
  return true;
}

void _sortMetadataSearchItems(
  List<VideoDiscoveryItem> items,
  VideoDiscoverySort sort,
) {
  if (sort == VideoDiscoverySort.relevance) return;
  items.sort((VideoDiscoveryItem left, VideoDiscoveryItem right) {
    final int primary = switch (sort) {
      VideoDiscoverySort.popularity => (right.metadataWork?.ratingVotes ?? -1)
          .compareTo(left.metadataWork?.ratingVotes ?? -1),
      VideoDiscoverySort.rating =>
        (right.score ?? -1).compareTo(left.score ?? -1),
      VideoDiscoverySort.releaseDate =>
        (right.releaseDate ?? '').compareTo(left.releaseDate ?? ''),
      VideoDiscoverySort.relevance => 0,
    };
    if (primary != 0) return primary;
    return left.reference.canonicalIdentityKey
        .compareTo(right.reference.canonicalIdentityKey);
  });
}

String _canonicalDiscoveryGenre(String? genre) {
  final String normalized = genre
          ?.trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[_-]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ') ??
      '';
  return switch (normalized) {
    'sci fi' || 'scifi' => 'science fiction',
    _ => normalized,
  };
}

String _canonicalRegion(String? region) {
  final String normalized = region?.trim().toLowerCase() ?? '';
  return switch (normalized) {
    'china' || '中国' || '中國' => 'CN',
    'japan' || '日本' => 'JP',
    'south korea' || 'korea' || '韩国' || '韓國' => 'KR',
    'united states' ||
    'united states of america' ||
    'usa' ||
    '美国' ||
    '美國' =>
      'US',
    'united kingdom' || 'great britain' || '英国' || '英國' => 'GB',
    'france' || '法国' || '法國' => 'FR',
    _ => normalized.toUpperCase(),
  };
}

List<ExternalProviderFailure> _deduplicateFailures(
  Iterable<ExternalProviderFailure> failures,
) {
  final Set<String> seen = <String>{};
  return <ExternalProviderFailure>[
    for (final ExternalProviderFailure failure in failures)
      if (seen.add(
        '${failure.providerId}:${failure.operation}:${failure.kind.name}',
      ))
        failure,
  ];
}

List<String> _uniqueStrings(Iterable<String> values) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String value in values)
      if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
  ];
}

T? _firstValue<T>(Iterable<T?> values) {
  for (final T? value in values) {
    if (value != null) return value;
  }
  return null;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final String? value in values) {
    if (value?.trim().isNotEmpty == true) return value!.trim();
  }
  return null;
}

int? _parseId(String? value) => int.tryParse(value ?? '');

class _ProviderResponse {
  const _ProviderResponse({
    required this.provider,
    required this.result,
    this.hasMore = false,
  });

  final VideoDiscoveryProvider provider;
  final ProviderBatchResult<VideoDiscoveryPage> result;
  final bool hasMore;

  List<VideoDiscoveryPage> get pages => result.items;
}

VideoDiscoveryRequest _requestAtPage(
  VideoDiscoveryRequest request,
  int page,
) =>
    VideoDiscoveryRequest(
      category: request.category,
      feed: request.feed,
      query: request.query,
      page: page,
      pageSize: request.pageSize,
      sort: request.sort,
      year: request.year,
      genre: request.genre,
      region: request.region,
    );
