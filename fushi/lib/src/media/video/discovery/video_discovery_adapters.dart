library;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_json.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;

/// TMDB 的真实发现/搜索适配器。
///
/// 认证信息只用于请求头或 query，不进入 cache key、错误消息与模型。电影与剧集的
/// 子请求彼此隔离，单类失败时仍返回另一类结果。
class TmdbVideoDiscoveryProvider implements VideoDiscoveryProvider {
  TmdbVideoDiscoveryProvider({
    String apiKey = '',
    String accessToken = '',
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.baseUrl = 'https://api.themoviedb.org/3',
    this.imageBaseUrl = 'https://image.tmdb.org/t/p/original',
    this.language = 'zh-CN',
  })  : assert(client == null || transport == null),
        _apiKey = apiKey.trim(),
        _accessToken = accessToken.trim(),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null;

  final String _apiKey;
  final String _accessToken;
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final String baseUrl;
  final String imageBaseUrl;
  final String language;

  @override
  String get id => 'tmdb';

  @override
  int get priority => 20;

  @override
  VideoDiscoveryCapabilities get capabilities => VideoDiscoveryCapabilities(
        categories: const <VideoDiscoveryCategory>{
          VideoDiscoveryCategory.movie,
          VideoDiscoveryCategory.tv,
        },
        feeds: const <VideoDiscoveryFeed>{
          VideoDiscoveryFeed.popular,
          VideoDiscoveryFeed.trending,
          VideoDiscoveryFeed.nowPlaying,
          VideoDiscoveryFeed.upcoming,
          VideoDiscoveryFeed.airing,
        },
        supportsSearch: true,
        supportsPaging: true,
      );

  bool get isAvailable => _apiKey.isNotEmpty || _accessToken.isNotEmpty;

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> discover(
    VideoDiscoveryRequest request,
  ) =>
      _load(request, search: false);

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> search(
    VideoDiscoveryRequest request,
  ) =>
      _load(request, search: true);

  Future<ProviderBatchResult<VideoDiscoveryPage>> _load(
    VideoDiscoveryRequest request, {
    required bool search,
  }) async {
    if (!isAvailable) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: search ? 'search' : 'discover',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'TMDB is not configured',
        ),
      );
    }
    final String query = request.query?.trim() ?? '';
    if (search && query.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final String rawGenre = request.genre?.trim() ?? '';
    if (rawGenre.isNotEmpty && _tmdbGenreId(rawGenre) == null) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: search ? 'search' : 'discover',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'TMDB does not recognize the requested genre filter',
        ),
      );
    }
    final String rawRegion = request.region?.trim() ?? '';
    if (rawRegion.isNotEmpty && !RegExp(r'^[A-Za-z]{2}$').hasMatch(rawRegion)) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: search ? 'search' : 'discover',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'TMDB requires a two-letter region code',
        ),
      );
    }
    final List<VideoMetadataMediaKind> kinds = _requestedKinds(request);
    if (kinds.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
            items: const <VideoDiscoveryItem>[],
            page: request.page,
            hasMore: false,
          ),
        ],
      );
    }

    final List<_DiscoveryCallResult> calls = await Future.wait(
      <Future<_DiscoveryCallResult>>[
        for (final VideoMetadataMediaKind kind in kinds)
          _loadKind(request, kind: kind, search: search),
      ],
    );
    final List<List<VideoDiscoveryItem>> successfulItems =
        <List<VideoDiscoveryItem>>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulKinds = 0;
    bool hasMore = false;
    for (final _DiscoveryCallResult call in calls) {
      if (call.failure case final ExternalProviderFailure failure) {
        failures.add(failure);
      } else {
        successfulKinds++;
        successfulItems.add(call.items);
        hasMore = hasMore || call.hasMore;
      }
    }
    return ProviderBatchResult<VideoDiscoveryPage>(
      items: successfulKinds == 0
          ? const <VideoDiscoveryPage>[]
          : <VideoDiscoveryPage>[
              VideoDiscoveryPage(
                items: _interleaveItems(successfulItems),
                page: request.page,
                hasMore: hasMore,
              ),
            ],
      failures: failures,
      successfulProviderCount: successfulKinds == 0 ? 0 : 1,
    );
  }

  Future<_DiscoveryCallResult> _loadKind(
    VideoDiscoveryRequest request, {
    required VideoMetadataMediaKind kind,
    required bool search,
  }) async {
    if (search) return _loadSearchKind(request, kind: kind);
    final String type = kind == VideoMetadataMediaKind.movie ? 'movie' : 'tv';
    final String path = _discoverPath(request, type);
    final Map<String, String> query = _queryParameters(
      request,
      kind: kind,
      search: false,
    );
    try {
      final VideoMetadataHttpResponse response = await _transport.get(
        Uri.parse('$baseUrl$path').replace(queryParameters: query),
        headers: <String, String>{
          'Accept': 'application/json',
          if (_accessToken.isNotEmpty) 'Authorization': 'Bearer $_accessToken',
        },
        operation: 'TMDB discover $type',
        cacheKey: 'tmdb:discover:$type:'
            '${request.category?.name}:${request.feed.name}:'
            '${request.query}:${request.page}:${request.pageSize}:'
            '${request.sort.name}:${request.year}:${request.genre}:'
            '${request.region}:$language',
      );
      final Map<String, Object?> payload = response.decodeJsonObject(
        operation: 'TMDB discover $type',
      );
      final int totalPages = metadataInt(payload['total_pages']) ?? 1;
      return _DiscoveryCallResult.success(
        <VideoDiscoveryItem>[
          for (final Object? node in metadataList(payload['results']))
            if (metadataObject(node) case final Map<String, Object?> item)
              if (_mapItem(item, kind) case final VideoDiscoveryItem mapped)
                mapped,
        ],
        hasMore: request.page < totalPages,
      );
    } on Object catch (error) {
      return _DiscoveryCallResult.failure(
        _providerFailure(
          providerId: id,
          operation: 'discover-$type',
          error: error,
        ),
      );
    }
  }

  /// TMDB's search endpoints do not implement genre/origin filters or the
  /// discovery sort modes. Pull a cumulative prefix, then apply only fields
  /// present in the returned media records before slicing the requested page.
  Future<_DiscoveryCallResult> _loadSearchKind(
    VideoDiscoveryRequest request, {
    required VideoMetadataMediaKind kind,
  }) async {
    final String type = kind == VideoMetadataMediaKind.movie ? 'movie' : 'tv';
    final int targetLength = request.page * request.pageSize;
    final int maximumRemotePages = (request.page * 10).clamp(20, 100);
    final List<_TmdbSearchEntry> matches = <_TmdbSearchEntry>[];
    int remotePage = 1;
    int totalPages = 1;
    int sourceOrder = 0;
    try {
      while (remotePage <= totalPages &&
          remotePage <= maximumRemotePages &&
          matches.length < targetLength) {
        final Map<String, String> query = _queryParameters(
          request,
          kind: kind,
          search: true,
          page: remotePage,
        );
        final VideoMetadataHttpResponse response = await _transport.get(
          Uri.parse('$baseUrl/search/$type').replace(queryParameters: query),
          headers: <String, String>{
            'Accept': 'application/json',
            if (_accessToken.isNotEmpty)
              'Authorization': 'Bearer $_accessToken',
          },
          operation: 'TMDB search $type',
          cacheKey: 'tmdb:search:$type:${request.category?.name}:'
              '${request.query}:$remotePage:${request.pageSize}:'
              '${request.sort.name}:${request.year}:${request.genre}:'
              '${request.region}:$language',
        );
        final Map<String, Object?> payload = response.decodeJsonObject(
          operation: 'TMDB search $type',
        );
        totalPages = (metadataInt(payload['total_pages']) ?? 1).clamp(1, 500);
        final List<Object?> results = metadataList(payload['results']);
        for (final Object? node in results) {
          final Map<String, Object?>? raw = metadataObject(node);
          if (raw == null || !_matchesSearchFilters(raw, kind, request)) {
            sourceOrder++;
            continue;
          }
          final VideoDiscoveryItem? mapped = _mapItem(raw, kind);
          if (mapped != null) {
            matches.add(
              _TmdbSearchEntry(
                item: mapped,
                popularity: metadataDouble(raw['popularity']),
                voteCount: metadataInt(raw['vote_count']) ?? 0,
                sourceOrder: sourceOrder,
              ),
            );
          }
          sourceOrder++;
        }
        remotePage++;
        if (results.isEmpty) break;
      }
      _sortTmdbSearchEntries(matches, request.sort);
      final int offset = (request.page - 1) * request.pageSize;
      final List<VideoDiscoveryItem> items = matches
          .skip(offset)
          .take(request.pageSize)
          .map((_TmdbSearchEntry entry) => entry.item)
          .toList(growable: false);
      final bool reachedSafetyLimit =
          remotePage > maximumRemotePages && remotePage <= totalPages;
      return _DiscoveryCallResult.success(
        items,
        hasMore: matches.length > offset + request.pageSize ||
            (!reachedSafetyLimit && remotePage <= totalPages),
      );
    } on Object catch (error) {
      return _DiscoveryCallResult.failure(
        _providerFailure(
          providerId: id,
          operation: 'search-$type',
          error: error,
        ),
      );
    }
  }

  bool _matchesSearchFilters(
    Map<String, Object?> item,
    VideoMetadataMediaKind kind,
    VideoDiscoveryRequest request,
  ) {
    final String date = metadataString(
          kind == VideoMetadataMediaKind.movie
              ? item['release_date']
              : item['first_air_date'],
        ) ??
        '';
    if (request.year != null && metadataYear(date) != request.year) {
      return false;
    }
    final int? genreId = int.tryParse(_tmdbGenreId(request.genre) ?? '');
    if (genreId != null &&
        !metadataList(item['genre_ids'])
            .map<int?>(metadataInt)
            .contains(genreId)) {
      return false;
    }
    final String region = request.region?.trim().toUpperCase() ?? '';
    if (region.isNotEmpty) {
      final Set<String> countries = metadataList(item['origin_country'])
          .map(metadataString)
          .whereType<String>()
          .map((String value) => value.trim().toUpperCase())
          .where((String value) => value.isNotEmpty)
          .toSet();
      if (!countries.contains(region)) return false;
    }
    return true;
  }

  List<VideoMetadataMediaKind> _requestedKinds(
    VideoDiscoveryRequest request,
  ) =>
      switch (request.category) {
        VideoDiscoveryCategory.movie => const <VideoMetadataMediaKind>[
            VideoMetadataMediaKind.movie,
          ],
        VideoDiscoveryCategory.tv => const <VideoMetadataMediaKind>[
            VideoMetadataMediaKind.tv,
          ],
        VideoDiscoveryCategory.anime => const <VideoMetadataMediaKind>[],
        null => VideoMetadataMediaKind.values,
      };

  String _discoverPath(VideoDiscoveryRequest request, String type) {
    final bool filtered = request.year != null ||
        request.genre?.trim().isNotEmpty == true ||
        request.region?.trim().isNotEmpty == true ||
        request.sort != VideoDiscoverySort.popularity;
    if (filtered) return '/discover/$type';
    return switch (request.feed) {
      VideoDiscoveryFeed.trending => '/trending/$type/week',
      VideoDiscoveryFeed.nowPlaying =>
        type == 'movie' ? '/movie/now_playing' : '/tv/on_the_air',
      VideoDiscoveryFeed.upcoming =>
        type == 'movie' ? '/movie/upcoming' : '/tv/on_the_air',
      VideoDiscoveryFeed.airing =>
        type == 'movie' ? '/movie/now_playing' : '/tv/on_the_air',
      VideoDiscoveryFeed.popular => '/$type/popular',
    };
  }

  Map<String, String> _queryParameters(
    VideoDiscoveryRequest request, {
    required VideoMetadataMediaKind kind,
    required bool search,
    int? page,
  }) {
    final String? genreId = _tmdbGenreId(request.genre);
    final String? region = request.region?.trim().toUpperCase();
    final String yearKey = kind == VideoMetadataMediaKind.movie
        ? 'primary_release_year'
        : 'first_air_date_year';
    return <String, String>{
      if (_apiKey.isNotEmpty) 'api_key': _apiKey,
      'language': language,
      'page': '${page ?? request.page}',
      if (search) 'query': request.query!.trim(),
      if (request.year != null) yearKey: '${request.year}',
      if (!search) 'sort_by': _tmdbSort(request.sort, kind),
      if (!search && genreId != null) 'with_genres': genreId,
      if (!search && region != null && region.isNotEmpty)
        if (kind == VideoMetadataMediaKind.movie)
          'region': region
        else
          'with_origin_country': region,
      if (!search && request.sort == VideoDiscoverySort.rating)
        'vote_count.gte': '20',
      'include_adult': 'false',
    };
  }

  String _tmdbSort(
    VideoDiscoverySort sort,
    VideoMetadataMediaKind kind,
  ) =>
      switch (sort) {
        VideoDiscoverySort.rating => 'vote_average.desc',
        VideoDiscoverySort.releaseDate => kind == VideoMetadataMediaKind.movie
            ? 'primary_release_date.desc'
            : 'first_air_date.desc',
        VideoDiscoverySort.relevance ||
        VideoDiscoverySort.popularity =>
          'popularity.desc',
      };

  VideoDiscoveryItem? _mapItem(
    Map<String, Object?> item,
    VideoMetadataMediaKind kind,
  ) {
    final int? idValue = metadataInt(item['id']);
    final String? title = metadataString(
      kind == VideoMetadataMediaKind.movie ? item['title'] : item['name'],
    );
    if (idValue == null || title == null) return null;
    final String id = '$idValue';
    final String? originalTitle = metadataString(
      kind == VideoMetadataMediaKind.movie
          ? item['original_title']
          : item['original_name'],
    );
    final String? releaseDate = metadataString(
      kind == VideoMetadataMediaKind.movie
          ? item['release_date']
          : item['first_air_date'],
    );
    final String? cover = _imageUrl(metadataString(item['poster_path']));
    final String? backdrop = _imageUrl(metadataString(item['backdrop_path']));
    final List<String> genres = <String>[
      for (final Object? value in metadataList(item['genre_ids']))
        if (metadataInt(value) case final int genreId)
          if (_tmdbGenreNames[genreId] case final String genre) genre,
    ];
    final VideoMetadataWork work = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: kind,
      title: title,
      originalTitle: originalTitle == title ? null : originalTitle,
      aliases: <String>[
        if (originalTitle != null && originalTitle != title) originalTitle,
      ],
      year: metadataYear(releaseDate),
      premiered: releaseDate,
      plot: metadataString(item['overview']),
      rating: metadataDouble(item['vote_average']),
      ratingVotes: metadataInt(item['vote_count']),
      originalLanguage: metadataString(item['original_language']),
      genres: genres,
      countries: <String>[
        for (final Object? country in metadataList(item['origin_country']))
          if (metadataString(country) case final String value) value,
      ],
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: id, isDefault: true),
      ],
      images: <VideoMetadataImage>[
        if (cover != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: cover,
            provider: VideoMetadataProviderKind.tmdb,
          ),
        if (backdrop != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: backdrop,
            provider: VideoMetadataProviderKind.tmdb,
          ),
      ],
    );
    return VideoDiscoveryItem.fromMetadataWork(
      work: work,
      discoveryCategory: kind == VideoMetadataMediaKind.movie
          ? VideoDiscoveryCategory.movie
          : VideoDiscoveryCategory.tv,
      externalId: id,
    );
  }

  String? _imageUrl(String? path) {
    if (path == null) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '$imageBaseUrl${path.startsWith('/') ? path : '/$path'}';
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

/// AniList 的真实季度、趋势、筛选与搜索适配器。
class AniListVideoDiscoveryProvider implements VideoDiscoveryProvider {
  AniListVideoDiscoveryProvider({
    http.Client? client,
    VideoMetadataHttpClient? transport,
    this.endpoint = 'https://graphql.anilist.co',
    DateTime Function()? now,
  })  : assert(client == null || transport == null),
        _transport = transport ?? VideoMetadataHttpClient(client: client),
        _ownsTransport = transport == null,
        _now = now ?? DateTime.now;

  static const String _query = r'''
query Discovery(
  $page: Int!,
  $perPage: Int!,
  $search: String,
  $sort: [MediaSort],
  $season: MediaSeason,
  $seasonYear: Int,
  $status: MediaStatus,
  $genre: String,
  $countryOfOrigin: CountryCode
) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage }
    media(
      type: ANIME,
      search: $search,
      sort: $sort,
      season: $season,
      seasonYear: $seasonYear,
      status: $status,
      genre: $genre,
      countryOfOrigin: $countryOfOrigin,
      isAdult: false
    ) {
      id
      idMal
      format
      title { native romaji english }
      synonyms
      startDate { year month day }
      episodes
      duration
      averageScore
      popularity
      trending
      description(asHtml: false)
      genres
      countryOfOrigin
      coverImage { extraLarge large }
      bannerImage
      siteUrl
      externalLinks { site url }
    }
  }
}
''';

  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final DateTime Function() _now;
  final String endpoint;

  @override
  String get id => 'anilist';

  @override
  int get priority => 10;

  @override
  VideoDiscoveryCapabilities get capabilities => VideoDiscoveryCapabilities(
        categories: const <VideoDiscoveryCategory>{
          VideoDiscoveryCategory.anime,
        },
        feeds: const <VideoDiscoveryFeed>{
          VideoDiscoveryFeed.popular,
          VideoDiscoveryFeed.trending,
          VideoDiscoveryFeed.nowPlaying,
          VideoDiscoveryFeed.upcoming,
          VideoDiscoveryFeed.airing,
        },
        supportsSearch: true,
        supportsPaging: true,
      );

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> discover(
    VideoDiscoveryRequest request,
  ) =>
      _load(request, search: false);

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> search(
    VideoDiscoveryRequest request,
  ) =>
      _load(request, search: true);

  Future<ProviderBatchResult<VideoDiscoveryPage>> _load(
    VideoDiscoveryRequest request, {
    required bool search,
  }) async {
    if (request.category != null &&
        request.category != VideoDiscoveryCategory.anime) {
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
            items: const <VideoDiscoveryItem>[],
            page: request.page,
            hasMore: false,
          ),
        ],
      );
    }
    final String query = request.query?.trim() ?? '';
    if (search && query.isEmpty) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a search query is required',
        ),
      );
    }
    final String rawGenre = request.genre?.trim() ?? '';
    final String? genre = _anilistGenre(request.genre);
    if (rawGenre.isNotEmpty && genre == null) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        ExternalProviderFailure(
          providerId: id,
          operation: search ? 'search' : 'discover',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'AniList does not recognize the requested genre filter',
        ),
      );
    }

    final DateTime now = _now();
    final ({String? season, int? year, String? status}) feed =
        _feedFilters(request, now);
    final Map<String, Object?> variables = <String, Object?>{
      'page': request.page,
      'perPage': request.pageSize.clamp(1, 50),
      if (search) 'search': query,
      'sort': <String>[_sort(request, search: search)],
      if (!search && feed.season != null) 'season': feed.season,
      if (request.year != null)
        'seasonYear': request.year
      else if (!search && feed.year != null)
        'seasonYear': feed.year,
      if (!search && feed.status != null) 'status': feed.status,
      if (genre != null) 'genre': genre,
      if (request.region?.trim().isNotEmpty == true)
        'countryOfOrigin': request.region!.trim().toUpperCase(),
    };
    try {
      final VideoMetadataHttpResponse response = await _transport.postJson(
        Uri.parse(endpoint),
        headers: const <String, String>{'Accept': 'application/json'},
        body: <String, Object?>{'query': _query, 'variables': variables},
        operation: 'AniList ${search ? 'search' : 'discover'}',
        cacheKey: 'anilist:${search ? 'search' : 'discover'}:'
            '${request.category?.name}:${request.feed.name}:${request.query}:'
            '${request.page}:${request.pageSize}:${request.sort.name}:'
            '${request.year}:${request.genre}:${request.region}:'
            '${feed.season}:${feed.year}:${feed.status}',
      );
      final Map<String, Object?> payload = response.decodeJsonObject(
        operation: 'AniList ${search ? 'search' : 'discover'}',
      );
      if (metadataList(payload['errors']).isNotEmpty) {
        throw const FormatException('AniList returned a GraphQL error');
      }
      final Map<String, Object?> page = metadataObject(
            metadataObject(payload['data'])?['Page'],
          ) ??
          const <String, Object?>{};
      final bool hasMore =
          metadataObject(page['pageInfo'])?['hasNextPage'] == true;
      return ProviderBatchResult<VideoDiscoveryPage>.success(
        <VideoDiscoveryPage>[
          VideoDiscoveryPage(
            items: <VideoDiscoveryItem>[
              for (final Object? node in metadataList(page['media']))
                if (metadataObject(node) case final Map<String, Object?> item)
                  if (_mapItem(item) case final VideoDiscoveryItem mapped)
                    mapped,
            ],
            page: request.page,
            hasMore: hasMore,
          ),
        ],
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoDiscoveryPage>.failure(
        _providerFailure(
          providerId: id,
          operation: search ? 'search' : 'discover',
          error: error,
        ),
      );
    }
  }

  ({String? season, int? year, String? status}) _feedFilters(
    VideoDiscoveryRequest request,
    DateTime now,
  ) {
    switch (request.feed) {
      case VideoDiscoveryFeed.airing:
        return (
          season: _season(now.month),
          year: now.year,
          status: 'RELEASING',
        );
      case VideoDiscoveryFeed.nowPlaying:
        return (season: null, year: null, status: 'RELEASING');
      case VideoDiscoveryFeed.upcoming:
        return (season: null, year: null, status: 'NOT_YET_RELEASED');
      case VideoDiscoveryFeed.popular:
      case VideoDiscoveryFeed.trending:
        return (season: null, year: null, status: null);
    }
  }

  String _sort(VideoDiscoveryRequest request, {required bool search}) {
    if (search && request.sort == VideoDiscoverySort.relevance) {
      return 'SEARCH_MATCH';
    }
    return switch (request.sort) {
      VideoDiscoverySort.rating => 'SCORE_DESC',
      VideoDiscoverySort.releaseDate => 'START_DATE_DESC',
      VideoDiscoverySort.relevance => 'SEARCH_MATCH',
      VideoDiscoverySort.popularity =>
        request.feed == VideoDiscoveryFeed.trending
            ? 'TRENDING_DESC'
            : 'POPULARITY_DESC',
    };
  }

  String _season(int month) => switch (month) {
        >= 1 && <= 3 => 'WINTER',
        >= 4 && <= 6 => 'SPRING',
        >= 7 && <= 9 => 'SUMMER',
        _ => 'FALL',
      };

  VideoDiscoveryItem? _mapItem(Map<String, Object?> item) {
    final int? idValue = metadataInt(item['id']);
    final Map<String, Object?> titles =
        metadataObject(item['title']) ?? const <String, Object?>{};
    final String? native = metadataString(titles['native']);
    final String? romaji = metadataString(titles['romaji']);
    final String? english = metadataString(titles['english']);
    final String? title = native ?? romaji ?? english;
    if (idValue == null || title == null) return null;
    final String id = '$idValue';
    final VideoMetadataMediaKind kind =
        metadataString(item['format']) == 'MOVIE'
            ? VideoMetadataMediaKind.movie
            : VideoMetadataMediaKind.tv;
    final String? premiered = _date(item['startDate']);
    final Map<String, Object?> cover =
        metadataObject(item['coverImage']) ?? const <String, Object?>{};
    final String? coverUrl =
        metadataString(cover['extraLarge']) ?? metadataString(cover['large']);
    final String? bannerUrl = metadataString(item['bannerImage']);
    final List<VideoMetadataId> ids = <VideoMetadataId>[
      VideoMetadataId(type: 'anilist', value: id, isDefault: true),
      if (metadataInt(item['idMal']) case final int malId)
        VideoMetadataId(type: 'mal', value: '$malId'),
      ..._externalIds(item['externalLinks']),
    ];
    final VideoMetadataWork work = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anilist,
      kind: kind,
      title: title,
      originalTitle: native == title ? null : native,
      aliases: metadataUniqueStrings(<String?>[
        native,
        romaji,
        english,
        for (final Object? synonym in metadataList(item['synonyms']))
          metadataString(synonym),
      ]).where((String value) => value != title).toList(),
      year: metadataYear(premiered),
      premiered: premiered,
      plot: metadataStripHtml(metadataString(item['description'])),
      rating: _score(item['averageScore']),
      ratingVotes: metadataInt(item['popularity']),
      runtimeMinutes: metadataInt(item['duration']),
      episodeCount: metadataInt(item['episodes']),
      genres: <String>[
        for (final Object? genre in metadataList(item['genres']))
          if (metadataString(genre) case final String value) value,
      ],
      countries: <String>[
        if (metadataString(item['countryOfOrigin']) case final String country)
          country,
      ],
      ids: ids,
      images: <VideoMetadataImage>[
        if (coverUrl != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: coverUrl,
            provider: VideoMetadataProviderKind.anilist,
          ),
        if (bannerUrl != null)
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: bannerUrl,
            provider: VideoMetadataProviderKind.anilist,
          ),
      ],
    );
    return VideoDiscoveryItem.fromMetadataWork(
      work: work,
      discoveryCategory: VideoDiscoveryCategory.anime,
      externalId: id,
    );
  }

  List<VideoMetadataId> _externalIds(Object? value) {
    final List<VideoMetadataId> ids = <VideoMetadataId>[];
    for (final Object? node in metadataList(value)) {
      final Map<String, Object?>? link = metadataObject(node);
      final String site = metadataString(link?['site'])?.toLowerCase() ?? '';
      final String? url = metadataString(link?['url']);
      final Uri? uri = url == null ? null : Uri.tryParse(url);
      if (site.contains('imdb') && uri != null) {
        for (final String segment in uri.pathSegments) {
          if (RegExp(r'^tt\d+$').hasMatch(segment)) {
            ids.add(VideoMetadataId(type: 'imdb', value: segment));
            break;
          }
        }
      }
    }
    return ids;
  }

  String? _date(Object? value) {
    final Map<String, Object?>? date = metadataObject(value);
    final int? year = metadataInt(date?['year']);
    if (year == null) return null;
    final int? month = metadataInt(date?['month']);
    final int? day = metadataInt(date?['day']);
    return <String>[
      '$year',
      if (month != null) month.toString().padLeft(2, '0'),
      if (day != null) day.toString().padLeft(2, '0'),
    ].join('-');
  }

  double? _score(Object? value) {
    final int? score = metadataInt(value);
    return score != null && score > 0 ? score / 10 : null;
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

class _TmdbSearchEntry {
  const _TmdbSearchEntry({
    required this.item,
    required this.sourceOrder,
    required this.voteCount,
    this.popularity,
  });

  final VideoDiscoveryItem item;
  final double? popularity;
  final int voteCount;
  final int sourceOrder;
}

void _sortTmdbSearchEntries(
  List<_TmdbSearchEntry> entries,
  VideoDiscoverySort sort,
) {
  entries.sort((_TmdbSearchEntry left, _TmdbSearchEntry right) {
    final int primary = switch (sort) {
      VideoDiscoverySort.relevance =>
        left.sourceOrder.compareTo(right.sourceOrder),
      VideoDiscoverySort.popularity =>
        (right.popularity ?? -1).compareTo(left.popularity ?? -1),
      VideoDiscoverySort.rating =>
        (right.item.score ?? -1).compareTo(left.item.score ?? -1),
      VideoDiscoverySort.releaseDate =>
        (right.item.releaseDate ?? '').compareTo(left.item.releaseDate ?? ''),
    };
    if (primary != 0) return primary;
    if (sort == VideoDiscoverySort.rating) {
      final int votes = right.voteCount.compareTo(left.voteCount);
      if (votes != 0) return votes;
    }
    return left.sourceOrder.compareTo(right.sourceOrder);
  });
}

class _DiscoveryCallResult {
  const _DiscoveryCallResult._({
    required this.items,
    required this.hasMore,
    this.failure,
  });

  factory _DiscoveryCallResult.success(
    List<VideoDiscoveryItem> items, {
    required bool hasMore,
  }) =>
      _DiscoveryCallResult._(items: items, hasMore: hasMore);

  factory _DiscoveryCallResult.failure(ExternalProviderFailure failure) =>
      _DiscoveryCallResult._(
        items: const <VideoDiscoveryItem>[],
        hasMore: false,
        failure: failure,
      );

  final List<VideoDiscoveryItem> items;
  final bool hasMore;
  final ExternalProviderFailure? failure;
}

List<VideoDiscoveryItem> _interleaveItems(
  List<List<VideoDiscoveryItem>> sources,
) {
  final List<VideoDiscoveryItem> result = <VideoDiscoveryItem>[];
  int index = 0;
  while (sources.any((List<VideoDiscoveryItem> source) {
    return index < source.length;
  })) {
    for (final List<VideoDiscoveryItem> source in sources) {
      if (index < source.length) result.add(source[index]);
    }
    index++;
  }
  return result;
}

ExternalProviderFailure _providerFailure({
  required String providerId,
  required String operation,
  required Object error,
}) {
  if (error is! VideoMetadataNetworkException) {
    return ExternalProviderFailure.fromException(
      providerId: providerId,
      operation: operation,
      error: error,
    );
  }
  final int? status = error.statusCode;
  final ExternalProviderFailureKind kind;
  if (status == 401) {
    kind = ExternalProviderFailureKind.unauthorized;
  } else if (status == 403) {
    kind = ExternalProviderFailureKind.forbidden;
  } else if (status == 404) {
    kind = ExternalProviderFailureKind.notFound;
  } else if (status == 429) {
    kind = ExternalProviderFailureKind.rateLimited;
  } else {
    kind = ExternalProviderFailureKind.network;
  }
  return ExternalProviderFailure(
    providerId: providerId,
    operation: operation,
    kind: kind,
    message: status == null
        ? 'provider network request failed'
        : 'provider returned HTTP $status',
    statusCode: status,
    retryAfter: error.retryAfter,
    retryable: status == null || status == 429 || status >= 500,
  );
}

const Map<int, String> _tmdbGenreNames = <int, String>{
  12: 'Adventure',
  14: 'Fantasy',
  16: 'Animation',
  18: 'Drama',
  27: 'Horror',
  28: 'Action',
  35: 'Comedy',
  36: 'History',
  37: 'Western',
  53: 'Thriller',
  80: 'Crime',
  99: 'Documentary',
  878: 'Science Fiction',
  9648: 'Mystery',
  10402: 'Music',
  10749: 'Romance',
  10751: 'Family',
  10752: 'War',
  10759: 'Action & Adventure',
  10762: 'Kids',
  10763: 'News',
  10764: 'Reality',
  10765: 'Sci-Fi & Fantasy',
  10766: 'Soap',
  10767: 'Talk',
  10768: 'War & Politics',
};

String? _tmdbGenreId(String? genre) {
  final String normalized = _canonicalGenre(genre);
  if (normalized.isEmpty) return null;
  for (final MapEntry<int, String> entry in _tmdbGenreNames.entries) {
    if (_canonicalGenre(entry.value) == normalized) return '${entry.key}';
  }
  return int.tryParse(normalized)?.toString();
}

String? _anilistGenre(String? genre) => const <String, String>{
      'action': 'Action',
      'adventure': 'Adventure',
      'comedy': 'Comedy',
      'drama': 'Drama',
      'ecchi': 'Ecchi',
      'fantasy': 'Fantasy',
      'horror': 'Horror',
      'mahou shoujo': 'Mahou Shoujo',
      'mecha': 'Mecha',
      'music': 'Music',
      'mystery': 'Mystery',
      'psychological': 'Psychological',
      'romance': 'Romance',
      'science fiction': 'Sci-Fi',
      'slice of life': 'Slice of Life',
      'sports': 'Sports',
      'supernatural': 'Supernatural',
      'thriller': 'Thriller',
    }[_canonicalGenre(genre)];

String _canonicalGenre(String? genre) {
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
