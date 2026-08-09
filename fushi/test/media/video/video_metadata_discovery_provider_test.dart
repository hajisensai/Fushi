import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/discovery/video_metadata_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';

void main() {
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
