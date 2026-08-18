import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/builtin_video_resource_sources.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/torrent/public_video_index_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

/// 只记录「有没有被问到」的替身。域门控与停用清单的正确性只能这样测：
/// 停用必须是**不参与查询**，而不是「查了再把结果丢掉」——后者照样打网络请求，
/// 失败照样进 failures 吓用户。
class _RecordingProvider implements VideoResourceProvider {
  _RecordingProvider(this.id, this.categories, {this.priority = 0});

  @override
  final String id;

  @override
  final Set<VideoDiscoveryCategory> categories;

  @override
  final int priority;

  int searchCalls = 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    searchCalls += 1;
    return ProviderBatchResult<VideoResourceCandidate>.success(
      const <VideoResourceCandidate>[],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

VideoResourceSearchRequest _request(VideoDiscoveryCategory? category) =>
    VideoResourceSearchRequest(
      query: 'query',
      media: category == null
          ? null
          : VideoMediaReference(
              providerId: 'tmdb',
              mediaId: '1',
              mediaKind: VideoMetadataMediaKind.movie,
              discoveryCategory: category,
              title: 'Title',
            ),
    );

void main() {
  late _RecordingProvider nyaa;
  late _RecordingProvider apibay;
  late _RecordingProvider knaben;
  late _RecordingProvider torznab;

  List<VideoResourceProvider> providers() => <VideoResourceProvider>[
        nyaa,
        apibay,
        knaben,
        torznab,
      ];

  setUp(() {
    nyaa = _RecordingProvider(
      kNyaaResourceProviderId,
      const <VideoDiscoveryCategory>{VideoDiscoveryCategory.anime},
      priority: 100,
    );
    apibay = _RecordingProvider(
      kApibayResourceProviderId,
      const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      },
      priority: 200,
    );
    knaben = _RecordingProvider(
      kKnabenResourceProviderId,
      const <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      },
      priority: 210,
    );
    // 空集 = 不限域（用户自配的 Torznab：搜什么由他填的分类决定）。
    torznab = _RecordingProvider(
      'torznab',
      const <VideoDiscoveryCategory>{},
      priority: 10,
    );
  });

  test('anime only reaches nyaa and the unrestricted torznab', () async {
    await VideoResourceRegistry(providers())
        .search(_request(VideoDiscoveryCategory.anime));
    expect(nyaa.searchCalls, 1);
    expect(torznab.searchCalls, 1);
    expect(apibay.searchCalls, 0);
    expect(knaben.searchCalls, 0);
  });

  test('movies reach the public indexers but never nyaa', () async {
    await VideoResourceRegistry(providers())
        .search(_request(VideoDiscoveryCategory.movie));
    expect(apibay.searchCalls, 1);
    expect(knaben.searchCalls, 1);
    expect(torznab.searchCalls, 1);
    expect(nyaa.searchCalls, 0);
  });

  test('tv reaches the public indexers but never nyaa', () async {
    await VideoResourceRegistry(providers())
        .search(_request(VideoDiscoveryCategory.tv));
    expect(apibay.searchCalls, 1);
    expect(knaben.searchCalls, 1);
    expect(nyaa.searchCalls, 0);
  });

  test('a request with no media identity only reaches unrestricted providers',
      () async {
    // 与 id 白名单时代逐字一致：那时 anime 为 false，Nyaa 同样不进。
    await VideoResourceRegistry(providers()).search(_request(null));
    expect(torznab.searchCalls, 1);
    expect(nyaa.searchCalls, 0);
    expect(apibay.searchCalls, 0);
    expect(knaben.searchCalls, 0);
  });

  test('a disabled source is never queried at all', () async {
    final ProviderBatchResult<VideoResourceCandidate> result =
        await VideoResourceRegistry(
      providers(),
      disabledProviderIds: <String>{kApibayResourceProviderId},
    ).search(_request(VideoDiscoveryCategory.movie));
    expect(apibay.searchCalls, 0);
    expect(knaben.searchCalls, 1);
    // 停用一家不等于「没有来源」：另一家答了，空态判据必须仍是普通空结果。
    expect(result.hasNoActiveProvider, isFalse);
  });

  test('disabling every applicable source yields the no-provider state',
      () async {
    final ProviderBatchResult<VideoResourceCandidate> result =
        await VideoResourceRegistry(
      providers(),
      disabledProviderIds: <String>{
        kApibayResourceProviderId,
        kKnabenResourceProviderId,
        'torznab',
      },
    ).search(_request(VideoDiscoveryCategory.movie));
    expect(apibay.searchCalls, 0);
    expect(knaben.searchCalls, 0);
    expect(torznab.searchCalls, 0);
    // PR#896 的空态：0 成功 0 失败 = 「没有来源可问」，不是「没搜到」。
    expect(result.hasNoActiveProvider, isTrue);
  });

  group('builtin source table', () {
    test('every descriptor id matches the provider it constructs', () {
      // 这张表同时驱动 provider 构造和设置页开关行。id 一旦与 provider.id 漂开，
      // 停用清单就写不进去：开关看着关了，搜索照样打网络。
      for (final BuiltinVideoResourceSource source
          in kBuiltinVideoResourceSources) {
        final VideoResourceProvider provider = source.create(
          MockClient((http.Request request) async => http.Response('', 200)),
        );
        expect(
          provider.id,
          source.id,
          reason: 'descriptor ${source.id} builds provider ${provider.id}',
        );
        provider.close();
      }
    });

    test('ids are unique and cover nyaa plus both public indexers', () {
      final List<String> ids = <String>[
        for (final BuiltinVideoResourceSource source
            in kBuiltinVideoResourceSources)
          source.id,
      ];
      expect(ids.toSet(), hasLength(ids.length));
      expect(
        ids,
        containsAll(<String>[
          kNyaaResourceProviderId,
          kApibayResourceProviderId,
          kKnabenResourceProviderId,
        ]),
      );
    });
  });
}
