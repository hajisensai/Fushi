import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/discovery/video_metadata_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_adapters.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';

void main() {
  test(
    'MAL search adapts distinct seasons with canonical detail lookups',
    () async {
      final MalVideoMetadataProvider metadata = _malSeasonsProvider();
      addTearDown(metadata.close);
      final VideoMetadataSearchDiscoveryProvider provider =
          VideoMetadataSearchDiscoveryProvider(
        provider: metadata,
        categories: const <VideoDiscoveryCategory>{
          VideoDiscoveryCategory.anime,
        },
      );

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.anime,
          query: 'Seihantai na Kimi to Boku',
        ),
      );

      expect(result.failures, isEmpty);
      final List<VideoDiscoveryItem> items = result.items.single.items;
      expect(items, hasLength(2));
      expect(
        items.map((VideoDiscoveryItem item) => item.reference.title),
        <String>[
          'Seihantai na Kimi to Boku',
          'Seihantai na Kimi to Boku 2nd Season',
        ],
      );
      expect(
        items.map(
          (VideoDiscoveryItem item) => item.confirmedLookup!.externalId,
        ),
        <String>['100', '101'],
      );
      expect(
        items.map((VideoDiscoveryItem item) => item.confirmedLookup!.provider),
        everyElement(VideoMetadataProviderKind.mal),
      );
      expect(
        items.map((VideoDiscoveryItem item) => item.reference.mediaKind),
        everyElement(VideoMetadataMediaKind.tv),
      );
      expect(provider.capabilities.feeds, isEmpty);
      expect(provider.capabilities.supportsSearch, isTrue);
    },
  );

  for (final VideoDiscoveryCategory? category in <VideoDiscoveryCategory?>[
    null,
    VideoDiscoveryCategory.anime,
  ]) {
    test(
      'MAL keeps both seasons in ${category?.name ?? 'all'} search when AniList fails',
      () async {
        final MalVideoMetadataProvider metadata = _malSeasonsProvider();
        final VideoDiscoveryService service = VideoDiscoveryService(
          providers: <VideoDiscoveryProvider>[
            VideoMetadataSearchDiscoveryProvider(
              provider: metadata,
              categories: const <VideoDiscoveryCategory>{
                VideoDiscoveryCategory.anime,
              },
              priority: 5,
            ),
            AniListVideoDiscoveryProvider(
              client: MockClient(
                (http.Request request) async => http.Response('', 503),
              ),
            ),
            TmdbVideoDiscoveryProvider(
              apiKey: 'test-key',
              client: MockClient(
                (http.Request request) async => http.Response(
                  jsonEncode(<String, Object?>{
                    'page': 1,
                    'total_pages': 1,
                    'results': <Object?>[
                      if (request.url.path.endsWith('/tv'))
                        <String, Object?>{
                          'id': 42,
                          'name': 'Seihantai na Kimi to Boku',
                          'first_air_date': '2026-01-11',
                          'genre_ids': <int>[16],
                        },
                    ],
                  }),
                  200,
                ),
              ),
            ),
          ],
          metadataProviders: <VideoMetadataProvider>[metadata],
          closesProviders: true,
        );
        addTearDown(service.close);

        final ProviderBatchResult<VideoDiscoveryPage> result =
            await service.load(
          VideoDiscoveryRequest(
            category: category,
            query: 'Seihantai na Kimi to Boku',
          ),
        );

        expect(result.isPartial, isTrue);
        expect(result.failures.single.providerId, 'anilist');
        final List<VideoDiscoveryItem> items = result.items.single.items;
        expect(
          items
              .where(
                (VideoDiscoveryItem item) =>
                    item.confirmedLookup?.provider ==
                    VideoMetadataProviderKind.mal,
              )
              .map(
                (VideoDiscoveryItem item) => item.confirmedLookup!.externalId,
              ),
          containsAll(<String>['100', '101']),
        );
        expect(
          items.where(
            (VideoDiscoveryItem item) =>
                item.reference.title == 'Seihantai na Kimi to Boku 2nd Season',
          ),
          hasLength(1),
        );
      },
    );
  }

  test('adapts anime metadata search without changing canonical media kind',
      () async {
    final _FakeMetadataProvider metadata = _FakeMetadataProvider();
    final VideoMetadataSearchDiscoveryProvider provider =
        VideoMetadataSearchDiscoveryProvider(
      provider: metadata,
      categories: const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.anime,
      },
    );

    final ProviderBatchResult<VideoDiscoveryPage> result =
        await provider.search(
      const VideoDiscoveryRequest(
        category: VideoDiscoveryCategory.anime,
        query: 'Anime',
      ),
    );

    expect(result.failures, isEmpty);
    expect(metadata.requestedKinds, VideoMetadataMediaKind.values);
    final List<VideoDiscoveryItem> items = result.items.single.items;
    expect(items, hasLength(2));
    expect(
      items.map((VideoDiscoveryItem item) => item.reference.discoveryCategory),
      everyElement(VideoDiscoveryCategory.anime),
    );
    expect(
      items.map((VideoDiscoveryItem item) => item.reference.mediaKind),
      containsAll(VideoMetadataMediaKind.values),
    );
    expect(items.first.metadataWork, isNotNull);
    expect(items.first.confirmedLookup, isNotNull);
  });

  test('reports discovery feeds as an unsupported capability', () async {
    final VideoMetadataSearchDiscoveryProvider provider =
        VideoMetadataSearchDiscoveryProvider(
      provider: _FakeMetadataProvider(),
      categories: const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
      },
    );

    final ProviderBatchResult<VideoDiscoveryPage> result =
        await provider.discover(const VideoDiscoveryRequest());

    expect(
        result.failures.single.kind, ExternalProviderFailureKind.unsupported);
    expect(provider.capabilities.feeds, isEmpty);
  });
}

MalVideoMetadataProvider _malSeasonsProvider() => MalVideoMetadataProvider(
      requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
      client: MockClient((http.Request request) async {
        expect(request.url.path, '/v4/anime');
        expect(request.url.queryParameters['q'], 'Seihantai na Kimi to Boku');
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <Object?>[
              if (request.url.queryParameters['type'] != 'movie')
                for (final int season in <int>[1, 2])
                  <String, Object?>{
                    'mal_id': season == 1 ? 100 : 101,
                    'title':
                        'Seihantai na Kimi to Boku${season == 1 ? '' : ' 2nd Season'}',
                    'type': 'TV',
                    'year': 2026,
                  },
            ],
          }),
          200,
        );
      }),
    );

class _FakeMetadataProvider implements VideoMetadataProvider {
  final List<VideoMetadataMediaKind> requestedKinds =
      <VideoMetadataMediaKind>[];

  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.anilist;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    requestedKinds.add(request.mediaKind);
    return <VideoMetadataWork>[
      VideoMetadataWork(
        provider: providerKind,
        kind: request.mediaKind,
        title: 'Anime ${request.mediaKind.name}',
        ids: <VideoMetadataId>[
          VideoMetadataId(
            type: 'anilist',
            value:
                request.mediaKind == VideoMetadataMediaKind.movie ? '1' : '2',
            isDefault: true,
          ),
        ],
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
