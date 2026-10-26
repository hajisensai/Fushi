// RSS 搜索站 provider：逐站回执、按站点域参与、实例过滤、翻页、resolve，
// 以及 registry 把多实例 provider 的回执逐站展开（原 Nyaa 内置 provider 的
// BUG-2794 逐查询回执契约原样迁到这里）。
import 'dart:convert';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String _hash(String c) => c * 40;

String _rss(List<({String title, String hash, int seeders})> items) {
  final StringBuffer out = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa"><channel>',
  );
  for (final ({String title, String hash, int seeders}) item in items) {
    out.write(
      '<item><title>${item.title}</title>'
      '<link>https://site.example/download/${item.hash}.torrent</link>'
      '<guid isPermaLink="true">https://site.example/view/${item.hash}</guid>'
      '<nyaa:infoHash>${item.hash}</nyaa:infoHash>'
      '<nyaa:seeders>${item.seeders}</nyaa:seeders>'
      '<nyaa:trusted>Yes</nyaa:trusted>'
      '</item>',
    );
  }
  out.write('</channel></rss>');
  return out.toString();
}

const String _emptyRss =
    '<?xml version="1.0"?><rss version="2.0"><channel><title>x</title></channel></rss>';

RssSearchSiteConfig _site(
  String id, {
  List<RssSearchDomain> domains = const <RssSearchDomain>[
    RssSearchDomain.anime,
  ],
  bool enabled = true,
  int priority = 100,
  String? template,
}) => RssSearchSiteConfig(
  id: id,
  name: id,
  urlTemplate: template ?? 'https://$id.example/rss?q={query}',
  enabled: enabled,
  priority: priority,
  domains: domains,
);

/// TMDB 列表卡片的形状：只有中文展示名 + 日文原名，罗马字在别名里。
VideoMediaReference _frieren({
  VideoDiscoveryCategory category = VideoDiscoveryCategory.anime,
}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '209867',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: category,
  title: '葬送的芙莉莲',
  originalTitle: '葬送のフリーレン',
  aliases: const <String>['Sousou no Frieren', '葬送のフリーレン'],
  tmdbId: 209867,
);

/// 罗马字查询有结果、CJK 查询结构有效但 0 条；记下每个请求。
MockClient _server(List<Uri> requests) =>
    MockClient((http.Request request) async {
      requests.add(request.url);
      final String query = request.url.queryParameters['q'] ?? '';
      if (!query.contains('Frieren')) return http.Response(_emptyRss, 200);
      return http.Response.bytes(
        utf8.encode(
          _rss(<({String title, String hash, int seeders})>[
            (
              title: '[SubsPlease] Sousou no Frieren - 01 (1080p)',
              hash: _hash('a'),
              seeders: 30,
            ),
            (
              title: '[SubsPlease] Sousou no Frieren - 02 (1080p)',
              hash: _hash('b'),
              seeders: 20,
            ),
          ]),
        ),
        200,
      );
    });

void main() {
  group('RssSearchProvider 逐站逐查询回执', () {
    test('日文原名 0 条 + 罗马字 2 条：合并去重、逐词计数，回执 providerId = rss:<siteId>', () async {
      final List<Uri> requests = <Uri>[];
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[_site('nyaa')],
        client: _server(requests),
      );
      addTearDown(provider.close);
      final VideoResourceSearchResult result =
          await provider.search(
                VideoResourceSearchRequest(
                  media: _frieren(),
                  query: '葬送のフリーレン',
                ),
              )
              as VideoResourceSearchResult;
      expect(requests.map((Uri u) => u.queryParameters['q']), <String>[
        '葬送のフリーレン',
        'Sousou no Frieren',
      ]);
      expect(result.items, hasLength(2));
      expect(result.successfulProviderCount, 1);
      final VideoResourceSourceReport report = result.sources.single;
      expect(report.providerId, 'rss:nyaa');
      expect(report.succeeded, isTrue);
      expect(report.itemCount, 2);
      expect(
        report.queries.map(
          (VideoResourceQueryReport q) => '${q.query}=${q.itemCount}',
        ),
        <String>['葬送のフリーレン=0', 'Sousou no Frieren=2'],
      );
      final VideoResourceCandidate first = result.items.first;
      expect(first.providerId, kRssResourceProviderId);
      expect(first.providerInstanceId, 'nyaa');
      expect(persistedVideoResourceProviderId(first), 'rss:nyaa');
      expect(first.releaseGroup, 'SubsPlease');
      expect(first.resolution, '1080p');
      expect(first.trusted, isTrue);
      expect(first.infoHash, _hash('a'));
      expect(first.magnetUri, isNull, reason: '只有 .torrent 地址时不造磁链');
    });

    test('一条查询失败、另一条成功：成功照交，失败记在该查询上（partial）', () async {
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[_site('nyaa')],
        client: MockClient((http.Request request) async {
          if (request.url.queryParameters['q'] == '葬送のフリーレン') {
            return http.Response('', 503);
          }
          return http.Response(
            _rss(<({String title, String hash, int seeders})>[
              (title: 'Frieren - 01', hash: _hash('a'), seeders: 1),
            ]),
            200,
          );
        }),
      );
      addTearDown(provider.close);
      final VideoResourceSearchResult result =
          await provider.search(
                VideoResourceSearchRequest(
                  media: _frieren(),
                  query: '葬送のフリーレン',
                ),
              )
              as VideoResourceSearchResult;
      expect(result.items, hasLength(1));
      expect(result.isPartial, isTrue);
      final VideoResourceSourceReport report = result.sources.single;
      expect(report.succeeded, isTrue);
      expect(
        report.queries.first.failure?.kind,
        ExternalProviderFailureKind.unavailable,
      );
      expect(report.queries.first.failure?.providerId, 'rss:nyaa');
      expect(report.queries.last.failure, isNull);
    });

    test('站点返回 HTML（被拦）：该站整体失败，不伪装成 0 条；另一个站照常', () async {
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[
          _site('blocked', priority: 1),
          _site('ok', priority: 2),
        ],
        client: MockClient((http.Request request) async {
          if (request.url.host == 'blocked.example') {
            return http.Response(
              '<!doctype html><html><body>Just a moment</body></html>',
              200,
            );
          }
          return http.Response(
            _rss(<({String title, String hash, int seeders})>[
              (title: 'Frieren - 01', hash: _hash('c'), seeders: 1),
            ]),
            200,
          );
        }),
      );
      addTearDown(provider.close);
      final VideoResourceSearchResult result =
          await provider.search(
                const VideoResourceSearchRequest(query: 'Frieren'),
              )
              as VideoResourceSearchResult;
      expect(
        result.sources.map((VideoResourceSourceReport r) => r.providerId),
        <String>['rss:blocked', 'rss:ok'],
      );
      expect(result.sources.first.failed, isTrue);
      expect(
        result.sources.first.failures.single.kind,
        ExternalProviderFailureKind.invalidResponse,
      );
      expect(result.sources.last.succeeded, isTrue);
      expect(result.successfulProviderCount, 1);
      expect(result.items.single.providerInstanceId, 'ok');
    });
  });

  group('按站点域参与', () {
    test('只勾动漫的站不进电影搜索、只勾小说的站从不进视频搜索；没有站适用时零请求零回执', () async {
      final List<Uri> requests = <Uri>[];
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[
          _site('anime'),
          _site('movies', domains: <RssSearchDomain>[RssSearchDomain.movie]),
          _site('books', domains: <RssSearchDomain>[RssSearchDomain.novel]),
          _site('off', enabled: false),
        ],
        client: _server(requests),
      );
      addTearDown(provider.close);
      expect(provider.categories, isEmpty, reason: '逐站裁域，provider 级报不限域');
      expect(provider.videoSites.map((RssSearchSiteConfig s) => s.id), <String>[
        'anime',
        'movies',
      ]);

      final VideoResourceSearchResult movie =
          await provider.search(
                VideoResourceSearchRequest(
                  media: _frieren(category: VideoDiscoveryCategory.movie),
                  query: 'Frieren',
                ),
              )
              as VideoResourceSearchResult;
      expect(
        movie.sources.map((VideoResourceSourceReport r) => r.providerId),
        <String>['rss:movies'],
      );
      expect(requests.map((Uri u) => u.host).toSet(), <String>{
        'movies.example',
      });

      requests.clear();
      final VideoResourceSearchResult keyword =
          await provider.search(
                const VideoResourceSearchRequest(query: 'Frieren'),
              )
              as VideoResourceSearchResult;
      expect(
        keyword.sources.map((VideoResourceSourceReport r) => r.providerId),
        <String>['rss:anime', 'rss:movies'],
      );

      requests.clear();
      final RssSearchProvider booksOnly = RssSearchProvider(
        sites: <RssSearchSiteConfig>[
          _site('books', domains: <RssSearchDomain>[RssSearchDomain.novel]),
        ],
        client: _server(requests),
      );
      addTearDown(booksOnly.close);
      final ProviderBatchResult<VideoResourceCandidate> none = await booksOnly
          .search(const VideoResourceSearchRequest(query: 'Frieren'));
      expect(requests, isEmpty);
      expect((none as VideoResourceSearchResult).sources, isEmpty);
      expect(none.hasNoActiveProvider, isTrue);
      expect(rssHasEnabledVideoSite(booksOnly.sites), isFalse);
      expect(rssHasEnabledVideoSite(provider.sites), isTrue);
    });

    test('providerInstanceId：订阅 / 重解析只打选中的那一个站', () async {
      final List<Uri> requests = <Uri>[];
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[_site('a'), _site('b')],
        client: _server(requests),
      );
      addTearDown(provider.close);
      final VideoResourceSearchResult result =
          await provider.search(
                const VideoResourceSearchRequest(
                  query: 'Frieren',
                  providerInstanceId: 'b',
                ),
              )
              as VideoResourceSearchResult;
      expect(requests.map((Uri u) => u.host).toSet(), <String>{'b.example'});
      expect(result.sources.single.providerId, 'rss:b');
    });

    test('翻页：模板有 {page} 才发第二页；没有就当翻到底，不重拉第一页', () async {
      final List<Uri> requests = <Uri>[];
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[
          _site(
            'paged',
            template: 'https://paged.example/rss?q={query}&p={page}',
          ),
          _site('flat'),
        ],
        client: _server(requests),
      );
      addTearDown(provider.close);
      await provider.search(
        const VideoResourceSearchRequest(query: 'Frieren', page: 2),
      );
      expect(
        requests.map((Uri u) => '${u.host}:${u.queryParameters['p']}'),
        <String>['paged.example:2'],
      );
    });
  });

  group('resolve', () {
    test('磁链候选直接成 payload；infoHash 以磁链 btih 为准（优先于 attr）', () async {
      final String good = 'magnet:?xt=urn:btih:${_hash('d')}&dn=x';
      final String bad = 'magnet:?xt=urn:btih:${_hash('e')}';
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[_site('dmhy')],
        client: MockClient(
          (http.Request request) async => http.Response(
            '<rss version="2.0"><channel>'
            '<item><title>good</title><enclosure url="${good.replaceAll('&', '&amp;')}" length="1" type="application/x-bittorrent"/></item>'
            '<item><title>bad</title><enclosure url="$bad"/><torznab:attr xmlns:torznab="http://torznab.com/schemas/2015/feed" name="infohash" value="${_hash('f')}"/></item>'
            '</channel></rss>',
            200,
          ),
        ),
      );
      addTearDown(provider.close);
      final List<VideoResourceCandidate> items = (await provider.search(
        const VideoResourceSearchRequest(query: 'x'),
      )).items;
      final VideoResourceCandidate goodCandidate = items.firstWhere(
        (VideoResourceCandidate c) => c.title == 'good',
      );
      expect(goodCandidate.magnetUri, good);
      final TorrentAddPayload payload = await provider.resolve(goodCandidate);
      expect(
        payload,
        isA<TorrentMagnetPayload>().having(
          (TorrentMagnetPayload p) => p.torrentId,
          'torrentId',
          _hash('d'),
        ),
      );

      final VideoResourceCandidate badCandidate = items.firstWhere(
        (VideoResourceCandidate c) => c.title == 'bad',
      );
      expect(badCandidate.infoHash, _hash('e'), reason: '磁链 btih 优先于 attr');
    });

    test('.torrent 地址：下载走共享 helper；响应体是磁链时按磁链处理并复核 hash', () async {
      final List<Uri> fetched = <Uri>[];
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[_site('nyaa')],
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('.torrent')) {
            fetched.add(request.url);
            return http.Response('magnet:?xt=urn:btih:${_hash('a')}', 200);
          }
          return http.Response(
            _rss(<({String title, String hash, int seeders})>[
              (title: 'Frieren - 01', hash: _hash('a'), seeders: 1),
            ]),
            200,
          );
        }),
      );
      addTearDown(provider.close);
      final VideoResourceCandidate candidate = (await provider.search(
        const VideoResourceSearchRequest(query: 'Frieren'),
      )).items.single;
      final TorrentAddPayload payload = await provider.resolve(candidate);
      expect(
        fetched.single.toString(),
        'https://site.example/download/${_hash('a')}.torrent',
      );
      expect(payload, isA<TorrentMagnetPayload>());
    });

    test('.torrent 下载 302 到不安全地址：拒绝，失败带 rss:<siteId>', () async {
      final RssSearchProvider provider = RssSearchProvider(
        sites: <RssSearchSiteConfig>[_site('nyaa')],
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('.torrent')) {
            return http.Response(
              '',
              302,
              headers: <String, String>{
                'location': 'http://evil.example/x.torrent',
              },
            );
          }
          return http.Response(
            _rss(<({String title, String hash, int seeders})>[
              (title: 'Frieren - 01', hash: _hash('a'), seeders: 1),
            ]),
            200,
          );
        }),
      );
      addTearDown(provider.close);
      final VideoResourceCandidate candidate = (await provider.search(
        const VideoResourceSearchRequest(query: 'Frieren'),
      )).items.single;
      await expectLater(
        provider.resolve(candidate),
        throwsA(
          isA<ExternalProviderFailure>()
              .having(
                (ExternalProviderFailure f) => f.providerId,
                'providerId',
                'rss:nyaa',
              )
              .having(
                (ExternalProviderFailure f) => f.kind,
                'kind',
                ExternalProviderFailureKind.invalidResponse,
              ),
        ),
      );
    });
  });

  group('RssSearchClient.searchSite（发现页用）', () {
    test('返回条目；HTTP 429 映射成 rateLimited 并带 Retry-After', () async {
      final RssSearchClient client = RssSearchClient(
        client: MockClient((http.Request request) async {
          if (request.url.queryParameters['q'] == 'limited') {
            return http.Response(
              '',
              429,
              headers: <String, String>{'retry-after': '30'},
            );
          }
          return http.Response(
            _rss(<({String title, String hash, int seeders})>[
              (title: 'Book Vol 1', hash: _hash('9'), seeders: 4),
            ]),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final RssSearchSiteConfig site = _site(
        'lit',
        domains: <RssSearchDomain>[RssSearchDomain.novel],
      );
      final List<RssSearchItem> items = await client.searchSite(site, 'book');
      expect(items.single.title, 'Book Vol 1');
      expect(items.single.seeders, 4);
      await expectLater(
        client.searchSite(site, 'limited'),
        throwsA(
          isA<ExternalProviderFailure>()
              .having(
                (ExternalProviderFailure f) => f.kind,
                'kind',
                ExternalProviderFailureKind.rateLimited,
              )
              .having(
                (ExternalProviderFailure f) => f.retryAfter,
                'retryAfter',
                const Duration(seconds: 30),
              )
              .having(
                (ExternalProviderFailure f) => f.providerId,
                'providerId',
                'rss:lit',
              ),
        ),
      );
    });
  });

  group('VideoResourceRegistry 逐站回执', () {
    test('多实例 provider 的回执逐站展开；单实例 provider 照旧合成一份', () async {
      final VideoResourceRegistry registry = VideoResourceRegistry(
        <VideoResourceProvider>[
          RssSearchProvider(
            sites: <RssSearchSiteConfig>[
              _site('a', priority: 1),
              _site('b', priority: 2),
            ],
            client: _server(<Uri>[]),
          ),
          _TimeoutProvider(),
        ],
      );
      addTearDown(registry.close);
      final VideoResourceSearchResult result = await registry.search(
        VideoResourceSearchRequest(media: _frieren(), query: '葬送のフリーレン'),
      );
      expect(
        result.sources.map((VideoResourceSourceReport r) => r.providerId),
        <String>['rss:a', 'rss:b', 'torznab'],
      );
      expect(result.sources.first.itemCount, 2);
      final VideoResourceSourceReport torznab = result.sources.last;
      expect(torznab.failed, isTrue);
      expect(torznab.queries.single.query, '葬送のフリーレン');
      // 两个站返回同一批种子：跨站按 info hash 去重。
      expect(result.items, hasLength(2));
    });
  });

  test('已移除内置源判据：裸 id 与带实例的持久化 id 都认，RSS / Torznab 不算', () {
    for (final String id in <String>[
      'nyaa',
      'nyaa:nyaa.si',
      'apibay:apibay.org',
      'knaben',
      ' NYAA ',
    ]) {
      expect(isRemovedBuiltinVideoResourceProvider(id), isTrue, reason: id);
    }
    for (final String id in <String>[
      'rss',
      'rss:nyaa',
      'torznab:nyaa',
      'manual',
    ]) {
      expect(isRemovedBuiltinVideoResourceProvider(id), isFalse, reason: id);
    }
  });
}

class _TimeoutProvider implements VideoResourceProvider {
  @override
  String get id => 'torznab';
  @override
  int get priority => 300;
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.failure(
    const ExternalProviderFailure(
      providerId: 'torznab',
      operation: 'search',
      kind: ExternalProviderFailureKind.timeout,
      message: 'timed out',
    ),
  );
  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) =>
      throw UnimplementedError();
  @override
  void close() {}
}
