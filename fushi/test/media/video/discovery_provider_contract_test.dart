import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

void main() {
  test('anime category keeps canonical movie/tv identity and metadata lookup',
      () {
    final VideoMetadataWork work = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.movie,
      title: 'Anime Film',
      plot: 'Plot',
      episodeGroupId: 'group-1',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '123', isDefault: true),
        VideoMetadataId(type: 'imdb', value: 'tt1234567'),
      ],
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'https://image.example/poster.jpg',
          provider: VideoMetadataProviderKind.tmdb,
        ),
      ],
    );

    final VideoDiscoveryItem item = VideoDiscoveryItem.fromMetadataWork(
      work: work,
      discoveryCategory: VideoDiscoveryCategory.anime,
    );

    expect(item.reference.discoveryCategory, VideoDiscoveryCategory.anime);
    expect(item.reference.mediaKind, VideoMetadataMediaKind.movie);
    expect(item.reference.identityKeys, contains('imdb:tt1234567'));
    expect(item.reference.identityKeys, contains('tmdb-movie:123'));
    expect(item.metadataWork, same(work));
    expect(item.confirmedLookup!.externalId, '123');
    expect(item.confirmedLookup!.episodeGroupId, 'group-1');
    expect(item.posterUrl, 'https://image.example/poster.jpg');
  });

  test('null request category is the all-filter sentinel', () {
    const VideoDiscoveryRequest request = VideoDiscoveryRequest();
    expect(request.category, isNull);
  });

  test('TMDB movie and TV IDs remain distinct across raw external IDs', () {
    final VideoMediaReference movie = VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '42',
      mediaKind: VideoMetadataMediaKind.movie,
      discoveryCategory: VideoDiscoveryCategory.movie,
      title: 'Movie',
      tmdbId: 42,
      externalIds: const <String, String>{'tmdb': '42'},
    );
    final VideoMediaReference series = VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '42',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.tv,
      title: 'Series',
      tmdbId: 42,
      externalIds: const <String, String>{'tmdb': '42'},
    );

    expect(movie.identityKeys, contains('tmdb-movie:42'));
    expect(series.identityKeys, contains('tmdb-tv:42'));
    expect(movie.identityKeys, isNot(contains('tmdb:42')));
    expect(series.identityKeys, isNot(contains('tmdb:42')));
    expect(movie.identityKeys.intersection(series.identityKeys), isEmpty);
  });

  test('empty success plus provider failure remains a partial batch', () {
    final ProviderBatchResult<int> result = ProviderBatchResult.merge<int>(
      <ProviderBatchResult<int>>[
        ProviderBatchResult<int>.success(const <int>[]),
        ProviderBatchResult<int>.failure(
          const ExternalProviderFailure(
            providerId: 'secondary',
            operation: 'search',
            kind: ExternalProviderFailureKind.unavailable,
            message: 'provider unavailable',
          ),
        ),
      ],
    );

    expect(result.items, isEmpty);
    expect(result.isPartial, isTrue);
    expect(result.isTotalFailure, isFalse);
  });
}
