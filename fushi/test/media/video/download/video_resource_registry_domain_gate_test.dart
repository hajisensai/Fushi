import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_providers.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

import '../../../torrent/nyaa_html_fixture.dart';

/// 只记录「有没有被问到」的替身（不限域的 Torznab）。域门控的正确性只能这样测：
/// 不该参与的源必须是**不参与查询**，而不是「查了再把结果丢掉」——后者照样打网络
/// 请求，失败照样进 failures 吓用户。
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

/// 每个用例一组独占主机名：Nyaa 客户端的请求节流表按 host 共享，用例之间共用
/// 同一个 host 会互相排队。
int _hostSerial = 0;

void main() {
  /// 各站点主机收到的请求数（经 `createBtSiteResourceProviders` 的 client 工厂）。
  late Map<String, int> hits;
  late String nyaaHost;
  late String apibayHost;
  late String knabenHost;
  late _RecordingProvider torznab;

  BtSiteConfig nyaaSite({
    Set<BtSiteDomain> domains = const <BtSiteDomain>{BtSiteDomain.anime},
    Map<BtSiteDomain, String> nyaaCategories = const <BtSiteDomain, String>{
      BtSiteDomain.anime: '1_0',
    },
    bool enabled = true,
  }) => BtSiteConfig(
    id: 'site-nyaa',
    baseUrl: Uri.parse('https://$nyaaHost'),
    format: BtSiteFormat.nyaa,
    domains: domains,
    nyaaCategories: nyaaCategories,
    enabled: enabled,
  );

  BtSiteConfig apibaySite({
    Set<BtSiteDomain> domains = const <BtSiteDomain>{
      BtSiteDomain.movie,
      BtSiteDomain.tv,
    },
    bool enabled = true,
  }) => BtSiteConfig(
    id: 'site-apibay',
    baseUrl: Uri.parse('https://$apibayHost'),
    format: BtSiteFormat.apibay,
    domains: domains,
    enabled: enabled,
  );

  BtSiteConfig knabenSite({bool enabled = true}) => BtSiteConfig(
    id: 'site-knaben',
    baseUrl: Uri.parse('https://$knabenHost/v1'),
    format: BtSiteFormat.knaben,
    domains: const <BtSiteDomain>{BtSiteDomain.movie, BtSiteDomain.tv},
    enabled: enabled,
  );

  Future<http.Client> clientFactory() async =>
      MockClient((http.Request request) async {
        final String host = request.url.host;
        hits[host] = (hits[host] ?? 0) + 1;
        if (host == nyaaHost) return http.Response(kNyaaNoResultsHtml, 200);
        if (host == apibayHost) return http.Response('[]', 200);
        return http.Response('{"hits":[]}', 200);
      });

  Future<VideoResourceRegistry> registryFor(
    List<BtSiteConfig> sites, {
    bool withTorznab = true,
  }) async {
    final VideoResourceRegistry registry =
        VideoResourceRegistry(<VideoResourceProvider>[
          ...await createBtSiteResourceProviders(sites, clientFactory),
          if (withTorznab) torznab,
        ]);
    addTearDown(registry.close);
    return registry;
  }

  int hitsOn(String host) => hits[host] ?? 0;

  setUp(() {
    hits = <String, int>{};
    _hostSerial += 1;
    nyaaHost = 'nyaa-$_hostSerial.bt.test';
    apibayHost = 'apibay-$_hostSerial.bt.test';
    knabenHost = 'knaben-$_hostSerial.bt.test';
    // 空集 = 不限域（用户自配的 Torznab：搜什么由他填的分类决定）。
    torznab = _RecordingProvider(
      'torznab',
      const <VideoDiscoveryCategory>{},
      priority: 10,
    );
  });

  List<BtSiteConfig> allSites() => <BtSiteConfig>[
    nyaaSite(),
    apibaySite(),
    knabenSite(),
  ];

  test(
    'anime only reaches the anime nyaa site and the unrestricted torznab',
    () async {
      final VideoResourceRegistry registry = await registryFor(allSites());
      await registry.search(_request(VideoDiscoveryCategory.anime));
      expect(hitsOn(nyaaHost), greaterThan(0));
      expect(torznab.searchCalls, 1);
      expect(hitsOn(apibayHost), 0);
      expect(hitsOn(knabenHost), 0);
    },
  );

  test(
    'movies reach the movie/tv JSON sites but never the anime-only site',
    () async {
      final VideoResourceRegistry registry = await registryFor(allSites());
      await registry.search(_request(VideoDiscoveryCategory.movie));
      expect(hitsOn(apibayHost), greaterThan(0));
      expect(hitsOn(knabenHost), greaterThan(0));
      expect(torznab.searchCalls, 1);
      expect(hitsOn(nyaaHost), 0);
    },
  );

  test(
    'tv reaches the movie/tv JSON sites but never the anime-only site',
    () async {
      final VideoResourceRegistry registry = await registryFor(allSites());
      await registry.search(_request(VideoDiscoveryCategory.tv));
      expect(hitsOn(apibayHost), greaterThan(0));
      expect(hitsOn(knabenHost), greaterThan(0));
      expect(hitsOn(nyaaHost), 0);
    },
  );

  test(
    'a request with no media identity only reaches unrestricted providers',
    () async {
      // 用户站点都限了域；没有作品身份 = 不知道该进哪个域，只有不限域的 Torznab 参与。
      final VideoResourceRegistry registry = await registryFor(allSites());
      await registry.search(_request(null));
      expect(torznab.searchCalls, 1);
      expect(hitsOn(nyaaHost), 0);
      expect(hitsOn(apibayHost), 0);
      expect(hitsOn(knabenHost), 0);
    },
  );

  test('a site only joins the domains the user ticked', () async {
    // apibay 格式能搜电影与剧集，但用户只勾了电影：剧集请求不该打到它。
    final VideoResourceRegistry registry = await registryFor(<BtSiteConfig>[
      apibaySite(domains: const <BtSiteDomain>{BtSiteDomain.movie}),
    ], withTorznab: false);
    final ProviderBatchResult<VideoResourceCandidate> tv = await registry
        .search(_request(VideoDiscoveryCategory.tv));
    expect(hitsOn(apibayHost), 0);
    expect(tv.hasNoActiveProvider, isTrue);
    await registry.search(_request(VideoDiscoveryCategory.movie));
    expect(hitsOn(apibayHost), greaterThan(0));
  });

  test('a nyaa-style site only joins domains it has a category for', () async {
    // 用户勾了动漫 + 电影，但站点分类下拉里没有电影对应的分类：电影不生效。
    final BtSiteConfig site = nyaaSite(
      domains: const <BtSiteDomain>{BtSiteDomain.anime, BtSiteDomain.movie},
    );
    expect(site.effectiveVideoCategories, <VideoDiscoveryCategory>{
      VideoDiscoveryCategory.anime,
    });
    final VideoResourceRegistry registry = await registryFor(<BtSiteConfig>[
      site,
    ], withTorznab: false);
    final ProviderBatchResult<VideoResourceCandidate> movie = await registry
        .search(_request(VideoDiscoveryCategory.movie));
    expect(hitsOn(nyaaHost), 0);
    expect(movie.hasNoActiveProvider, isTrue);
  });

  test('a disabled site is never queried at all', () async {
    final VideoResourceRegistry registry = await registryFor(<BtSiteConfig>[
      nyaaSite(),
      apibaySite(enabled: false),
      knabenSite(),
    ]);
    expect(
      registry.providers.map((VideoResourceProvider p) => p.id),
      isNot(contains('apibay:site-apibay')),
    );
    final ProviderBatchResult<VideoResourceCandidate> result = await registry
        .search(_request(VideoDiscoveryCategory.movie));
    expect(hitsOn(apibayHost), 0);
    expect(hitsOn(knabenHost), greaterThan(0));
    // 停用一家不等于「没有来源」：另一家答了，空态判据必须仍是普通空结果。
    expect(result.hasNoActiveProvider, isFalse);
  });

  test(
    'disabling every applicable site yields the no-provider state',
    () async {
      final VideoResourceRegistry registry = await registryFor(<BtSiteConfig>[
        nyaaSite(),
        apibaySite(enabled: false),
        knabenSite(enabled: false),
      ], withTorznab: false);
      final ProviderBatchResult<VideoResourceCandidate> result = await registry
          .search(_request(VideoDiscoveryCategory.movie));
      expect(hitsOn(apibayHost), 0);
      expect(hitsOn(knabenHost), 0);
      expect(hitsOn(nyaaHost), 0);
      // PR#896 的空态：0 成功 0 失败 = 「没有来源可问」，不是「没搜到」。
      expect(result.hasNoActiveProvider, isTrue);
    },
  );

  test(
    'no user sites: no domain has any provider (nothing is built in)',
    () async {
      final List<VideoResourceProvider> providers =
          await createBtSiteResourceProviders(const <BtSiteConfig>[], () async {
            fail('no site → no client should be built');
          });
      expect(providers, isEmpty);
      final VideoResourceRegistry registry = VideoResourceRegistry(providers);
      addTearDown(registry.close);
      for (final VideoDiscoveryCategory category
          in VideoDiscoveryCategory.values) {
        expect(
          registry.providers.where(
            (VideoResourceProvider p) =>
                videoResourceProviderApplies(p, category),
          ),
          isEmpty,
          reason: '$category 不该有任何来源',
        );
        final ProviderBatchResult<VideoResourceCandidate> result =
            await registry.search(_request(category));
        expect(result.hasNoActiveProvider, isTrue, reason: '$category');
      }
      expect(hits, isEmpty);
    },
  );

  group('site → provider wiring', () {
    test('provider id is <format>:<siteId> and domains equal the effective '
        'video domains', () async {
      final List<BtSiteConfig> sites = allSites();
      final List<VideoResourceProvider> providers =
          await createBtSiteResourceProviders(sites, clientFactory);
      addTearDown(() {
        for (final VideoResourceProvider provider in providers) {
          provider.close();
        }
      });
      // id 一旦与站点漂开，订阅 / 任务上持久化的 provider id 就解析不回这个站。
      expect(providers.map((VideoResourceProvider p) => p.id), <String>[
        for (final BtSiteConfig site in sites) site.providerId,
      ]);
      expect(providers.map((VideoResourceProvider p) => p.id), <String>[
        'nyaa:site-nyaa',
        'apibay:site-apibay',
        'knaben:site-knaben',
      ]);
      for (int i = 0; i < sites.length; i++) {
        expect(
          providers[i].categories,
          sites[i].effectiveVideoCategories,
          reason: sites[i].id,
        );
      }
    });

    test('a site with no effective video domain registers nothing', () async {
      final List<VideoResourceProvider> providers =
          await createBtSiteResourceProviders(<BtSiteConfig>[
            // 只勾了发现页域（小说）：资源搜索面没有它。
            nyaaSite(
              domains: const <BtSiteDomain>{BtSiteDomain.novel},
              nyaaCategories: const <BtSiteDomain, String>{
                BtSiteDomain.novel: '3_0',
              },
            ),
          ], clientFactory);
      expect(providers, isEmpty);
    });
  });
}
