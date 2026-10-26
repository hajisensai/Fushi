import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 只记录「有没有被问到」的替身。域门控的正确性只能这样测：不适用的源必须是
/// **不参与查询**，而不是「查了再把结果丢掉」——后者照样打网络请求，失败照样进
/// failures 吓用户。
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

RssSearchSiteConfig _site(String id, List<RssSearchDomain> domains) =>
    RssSearchSiteConfig(
      id: id,
      name: id,
      urlTemplate: 'https://$id.example/rss?q={query}',
      domains: domains,
    );

void main() {
  group('provider 自报域（VideoResourceProvider.categories）', () {
    late _RecordingProvider animeOnly;
    late _RecordingProvider liveAction;
    late _RecordingProvider torznab;

    List<VideoResourceProvider> providers() => <VideoResourceProvider>[
      animeOnly,
      liveAction,
      torznab,
    ];

    setUp(() {
      animeOnly = _RecordingProvider(
        'anime-only',
        const <VideoDiscoveryCategory>{VideoDiscoveryCategory.anime},
        priority: 100,
      );
      liveAction = _RecordingProvider(
        'live-action',
        const <VideoDiscoveryCategory>{
          VideoDiscoveryCategory.movie,
          VideoDiscoveryCategory.tv,
        },
        priority: 200,
      );
      // 空集 = 不限域（用户自配的 Torznab：搜什么由他填的分类决定）。
      torznab = _RecordingProvider(
        'torznab',
        const <VideoDiscoveryCategory>{},
        priority: 10,
      );
    });

    test('anime 只问声明了 anime 的源与不限域的源', () async {
      await VideoResourceRegistry(
        providers(),
      ).search(_request(VideoDiscoveryCategory.anime));
      expect(animeOnly.searchCalls, 1);
      expect(torznab.searchCalls, 1);
      expect(liveAction.searchCalls, 0);
    });

    test('movie / tv 不问只声明 anime 的源', () async {
      await VideoResourceRegistry(
        providers(),
      ).search(_request(VideoDiscoveryCategory.movie));
      await VideoResourceRegistry(
        providers(),
      ).search(_request(VideoDiscoveryCategory.tv));
      expect(liveAction.searchCalls, 2);
      expect(torznab.searchCalls, 2);
      expect(animeOnly.searchCalls, 0);
    });

    test('没有作品身份的请求只问不限域的源', () async {
      await VideoResourceRegistry(providers()).search(_request(null));
      expect(torznab.searchCalls, 1);
      expect(animeOnly.searchCalls, 0);
      expect(liveAction.searchCalls, 0);
    });

    test('没有任何源适用：0 成功 0 失败 = 「没有来源可问」（PR#896 的空态）', () async {
      final ProviderBatchResult<VideoResourceCandidate> result =
          await VideoResourceRegistry(<VideoResourceProvider>[
            animeOnly,
          ]).search(_request(VideoDiscoveryCategory.movie));
      expect(animeOnly.searchCalls, 0);
      expect(result.hasNoActiveProvider, isTrue);
    });
  });

  group('RSS 搜索站按每个站自己勾的域参与（仓库不再内置任何 BT 搜索站）', () {
    late List<Uri> requests;
    late VideoResourceRegistry registry;

    setUp(() {
      requests = <Uri>[];
      registry = VideoResourceRegistry(<VideoResourceProvider>[
        RssSearchProvider(
          sites: <RssSearchSiteConfig>[
            _site('anime', <RssSearchDomain>[RssSearchDomain.anime]),
            _site('films', <RssSearchDomain>[
              RssSearchDomain.movie,
              RssSearchDomain.tv,
            ]),
            _site('books', <RssSearchDomain>[RssSearchDomain.novel]),
          ],
          client: MockClient((http.Request request) async {
            requests.add(request.url);
            return http.Response(
              '<rss version="2.0"><channel></channel></rss>',
              200,
            );
          }),
        ),
      ]);
      addTearDown(registry.close);
    });

    Set<String> hosts() => requests.map((Uri u) => u.host).toSet();

    test('anime 只打勾了动漫的站', () async {
      final VideoResourceSearchResult result = await registry.search(
        _request(VideoDiscoveryCategory.anime),
      );
      expect(hosts(), <String>{'anime.example'});
      expect(
        result.sources.map((VideoResourceSourceReport r) => r.providerId),
        <String>['rss:anime'],
      );
    });

    test('movie 只打勾了电影的站；只勾小说的站从不进视频搜索', () async {
      await registry.search(_request(VideoDiscoveryCategory.movie));
      expect(hosts(), <String>{'films.example'});
    });

    test('纯关键词搜索：所有勾了视频域的站都参与', () async {
      await registry.search(_request(null));
      expect(hosts(), <String>{'anime.example', 'films.example'});
    });
  });
}
