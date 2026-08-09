/// Provider-neutral discovery contracts used by the video module.
library;

import 'package:hibiki/src/media/external_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';

enum VideoDiscoveryCategory { movie, tv, anime }

enum VideoDiscoveryFeed { popular, trending, nowPlaying, upcoming, airing }

enum VideoDiscoverySort { relevance, popularity, rating, releaseDate }

/// A provider-neutral identity that can be passed to resource and subtitle
/// providers without depending on a database row.
class VideoMediaReference {
  VideoMediaReference({
    required this.providerId,
    required this.mediaId,
    required this.mediaKind,
    required this.discoveryCategory,
    required this.title,
    this.originalTitle,
    Iterable<String> aliases = const <String>[],
    this.year,
    this.season,
    this.episode,
    this.tmdbId,
    this.imdbId,
    this.tvdbId,
    this.anilistId,
    this.bangumiId,
    Map<String, String> externalIds = const <String, String>{},
  })  : aliases = List<String>.unmodifiable(aliases),
        externalIds = Map<String, String>.unmodifiable(externalIds);

  final String providerId;
  final String mediaId;

  /// Canonical persisted type. Anime still maps to movie or tv here.
  final VideoMetadataMediaKind mediaKind;

  /// Discovery-only taxonomy. For example, an anime film is
  /// `discoveryCategory=anime` and `mediaKind=movie`.
  final VideoDiscoveryCategory discoveryCategory;
  final String title;
  final String? originalTitle;
  final List<String> aliases;
  final int? year;
  final int? season;
  final int? episode;
  final int? tmdbId;
  final String? imdbId;
  final int? tvdbId;
  final int? anilistId;
  final int? bangumiId;
  final Map<String, String> externalIds;

  /// All strong identity keys, ordered from cross-provider to provider-local.
  Set<String> get identityKeys {
    final Set<String> keys = <String>{};
    void add(String namespace, Object? value) {
      final String normalized = value?.toString().trim().toLowerCase() ?? '';
      if (normalized.isNotEmpty) keys.add('$namespace:$normalized');
    }

    add('imdb', imdbId);
    add('tmdb-${mediaKind.name}', tmdbId);
    add('tvdb', tvdbId);
    add('anilist', anilistId);
    add('bangumi', bangumiId);
    for (final MapEntry<String, String> entry in externalIds.entries) {
      final String namespace = entry.key.trim().toLowerCase();
      // TMDB's movie and TV numeric IDs live in independent namespaces. A
      // raw `tmdb:<id>` key would make an all-category page discard one card
      // whenever a movie and a series happen to share that number.
      add(
        namespace == 'tmdb' ? 'tmdb-${mediaKind.name}' : namespace,
        entry.value,
      );
    }
    add('${providerId.trim().toLowerCase()}-${mediaKind.name}', mediaId);
    return Set<String>.unmodifiable(keys);
  }

  String get canonicalIdentityKey => identityKeys.first;
}

class VideoDiscoveryRequest {
  const VideoDiscoveryRequest({
    this.category,
    this.feed = VideoDiscoveryFeed.popular,
    this.query,
    this.page = 1,
    this.pageSize = 20,
    this.sort = VideoDiscoverySort.popularity,
    this.year,
    this.genre,
    this.region,
  })  : assert(page > 0),
        assert(pageSize > 0);

  /// null means no category filter (the UI's "all" sentinel).
  final VideoDiscoveryCategory? category;
  final VideoDiscoveryFeed feed;
  final String? query;
  final int page;
  final int pageSize;
  final VideoDiscoverySort sort;
  final int? year;
  final String? genre;
  final String? region;

  bool get isSearch => query?.trim().isNotEmpty == true;
}

class VideoDiscoveryItem {
  VideoDiscoveryItem({
    required this.reference,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.score,
    this.releaseDate,
    Iterable<String> genres = const <String>[],
    this.metadataWork,
    this.confirmedLookup,
  }) : genres = List<String>.unmodifiable(genres);

  factory VideoDiscoveryItem.fromMetadataWork({
    required VideoMetadataWork work,
    required VideoDiscoveryCategory discoveryCategory,
    String? externalId,
  }) {
    final String providerId = work.provider.name;
    final String resolvedId = externalId ??
        _metadataId(work, providerId) ??
        _defaultMetadataId(work) ??
        (throw ArgumentError('metadata work has no provider identity'));
    return VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: providerId,
        mediaId: resolvedId,
        mediaKind: work.kind,
        discoveryCategory: discoveryCategory,
        title: work.title,
        originalTitle: work.originalTitle,
        aliases: work.aliases,
        year: work.year,
        tmdbId: int.tryParse(_metadataId(work, 'tmdb') ?? ''),
        imdbId: _metadataId(work, 'imdb'),
        tvdbId: int.tryParse(_metadataId(work, 'tvdb') ?? ''),
        anilistId: int.tryParse(_metadataId(work, 'anilist') ?? ''),
        bangumiId: int.tryParse(_metadataId(work, 'bangumi') ?? ''),
        externalIds: <String, String>{
          for (final VideoMetadataId id in work.ids) id.type: id.value,
        },
      ),
      overview: work.plot,
      posterUrl: _metadataImage(work, VideoMetadataImageKind.cover),
      backdropUrl: _metadataImage(work, VideoMetadataImageKind.backdrop),
      score: work.rating,
      releaseDate: work.premiered,
      genres: work.genres,
      metadataWork: work,
      confirmedLookup: VideoMetadataLookup(
        provider: work.provider,
        externalId: resolvedId,
        mediaKind: work.kind,
        episodeGroupId: work.episodeGroupId,
      ),
    );
  }

  final VideoMediaReference reference;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final double? score;
  final String? releaseDate;
  final List<String> genres;

  /// Provider-normalized summary/full work. Keeping the original neutral work
  /// prevents discovery → detail → confirmed scrape from losing IDs, images,
  /// episode groups, or other provider fields.
  final VideoMetadataWork? metadataWork;
  final VideoMetadataLookup? confirmedLookup;
}

class VideoDiscoveryPage {
  VideoDiscoveryPage({
    required Iterable<VideoDiscoveryItem> items,
    required this.page,
    required this.hasMore,
    this.nextCursor,
  }) : items = List<VideoDiscoveryItem>.unmodifiable(items);

  final List<VideoDiscoveryItem> items;
  final int page;
  final bool hasMore;
  final String? nextCursor;
}

class VideoDiscoveryCapabilities {
  VideoDiscoveryCapabilities({
    Iterable<VideoDiscoveryCategory> categories =
        const <VideoDiscoveryCategory>{
      VideoDiscoveryCategory.movie,
      VideoDiscoveryCategory.tv,
      VideoDiscoveryCategory.anime,
    },
    Iterable<VideoDiscoveryFeed> feeds = const <VideoDiscoveryFeed>{
      VideoDiscoveryFeed.popular
    },
    this.supportsSearch = true,
    this.supportsPaging = true,
  })  : categories = Set<VideoDiscoveryCategory>.unmodifiable(categories),
        feeds = Set<VideoDiscoveryFeed>.unmodifiable(feeds);

  final Set<VideoDiscoveryCategory> categories;
  final Set<VideoDiscoveryFeed> feeds;
  final bool supportsSearch;
  final bool supportsPaging;
}

String? _metadataId(VideoMetadataWork work, String type) {
  final String normalized = type.toLowerCase();
  for (final VideoMetadataId id in work.ids) {
    if (id.type.toLowerCase() == normalized && id.value.trim().isNotEmpty) {
      return id.value.trim();
    }
  }
  return null;
}

String? _defaultMetadataId(VideoMetadataWork work) {
  for (final VideoMetadataId id in work.ids) {
    if (id.isDefault && id.value.trim().isNotEmpty) return id.value.trim();
  }
  return null;
}

String? _metadataImage(VideoMetadataWork work, VideoMetadataImageKind kind) {
  for (final VideoMetadataImage image in work.images) {
    if (image.kind == kind && image.url.trim().isNotEmpty) return image.url;
  }
  return null;
}

abstract interface class VideoDiscoveryProvider {
  String get id;

  /// Lower values run first and win provider-local tie breaks.
  int get priority;
  VideoDiscoveryCapabilities get capabilities;

  Future<ProviderBatchResult<VideoDiscoveryPage>> discover(
    VideoDiscoveryRequest request,
  );

  Future<ProviderBatchResult<VideoDiscoveryPage>> search(
    VideoDiscoveryRequest request,
  );

  void close();
}
