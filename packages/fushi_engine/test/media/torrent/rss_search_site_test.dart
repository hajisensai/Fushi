import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:test/test.dart';

RssSearchSiteConfig _site({
  String id = 'nyaa',
  String template = 'https://nyaa.si/?page=rss&q={query}&c=1_0&f=0',
  bool enabled = true,
  Iterable<RssSearchDomain> domains = const <RssSearchDomain>[
    RssSearchDomain.anime,
  ],
  bool allowInsecureHttp = false,
}) => RssSearchSiteConfig(
  id: id,
  name: 'Nyaa',
  urlTemplate: template,
  enabled: enabled,
  domains: domains,
  allowInsecureHttp: allowInsecureHttp,
);

void main() {
  group('RssSearchSiteConfig 校验', () {
    test('合法模板：https 带 {query}；回环 / 显式放行的明文 HTTP 也合法', () {
      expect(_site().urlTemplate, contains('{query}'));
      expect(
        _site(template: 'http://localhost:9696/rss?q={query}').urlTemplate,
        startsWith('http://localhost'),
      );
      expect(
        _site(
          template: 'http://192.168.1.2/rss?q={query}',
          allowInsecureHttp: true,
        ).allowInsecureHttp,
        isTrue,
      );
    });

    test(
      '非法：缺 {query} / 非 http(s) / 无 host / user info / fragment / 未放行明文 HTTP',
      () {
        for (final String template in <String>[
          '',
          'https://nyaa.si/?page=rss&q=fixed',
          'ftp://x.example/{query}',
          'https:///rss?q={query}',
          'https://u:p@x.example/rss?q={query}',
          'https://x.example/rss?q={query}#frag',
          'http://x.example/rss?q={query}',
        ]) {
          expect(
            () => _site(template: template),
            throwsArgumentError,
            reason: template,
          );
          expect(validateRssSearchUrlTemplate(template), isNotNull);
        }
        expect(validateRssSearchUrlTemplate(_site().urlTemplate), isNull);
      },
    );

    test('id 必须非空且不含 : 或 ,（订阅 provider id 是 rss:<id>）', () {
      for (final String id in <String>['', ' a', 'a:b', 'a,b']) {
        expect(() => _site(id: id), throwsArgumentError, reason: id);
      }
    });
  });

  group('模板展开', () {
    test('{query} URL 编码、{page} 替换为页码', () {
      final RssSearchSiteConfig site = _site(
        template: 'https://x.example/rss?q={query}&p={page}',
      );
      final Uri uri = site.buildSearchUri('葬送 & Frieren', page: 3);
      expect(uri.queryParameters['q'], '葬送 & Frieren');
      expect(uri.queryParameters['p'], '3');
      expect(site.supportsPaging, isTrue);
      expect(_site().supportsPaging, isFalse);
      expect(() => site.buildSearchUri('x', page: 0), throwsArgumentError);
    });

    test('路径里的 {query} 也展开（bangumi.moe 形态）', () {
      final Uri uri = _site(
        template: 'https://bangumi.moe/rss/search/{query}',
      ).buildSearchUri('Frieren 1080p');
      expect(uri.toString(), 'https://bangumi.moe/rss/search/Frieren+1080p');
    });
  });

  group('域', () {
    test('视频域 ↔ VideoDiscoveryCategory、发现域 ↔ DiscoveryMediaKind 双向一致', () {
      for (final VideoDiscoveryCategory category
          in VideoDiscoveryCategory.values) {
        expect(
          RssSearchDomain.fromVideoCategory(category).videoCategory,
          category,
        );
      }
      for (final DiscoveryMediaKind kind in DiscoveryMediaKind.values) {
        expect(RssSearchDomain.fromDiscoveryKind(kind).discoveryKind, kind);
      }
      for (final RssSearchDomain domain in RssSearchDomain.values) {
        expect(
          (domain.videoCategory == null) != (domain.discoveryKind == null),
          isTrue,
          reason: '${domain.name} 恰属于一边',
        );
      }
    });

    test('appliesToVideo：停用 / 没勾视频域不参与；纯关键词搜索（null）任何视频站都参与', () {
      final RssSearchSiteConfig anime = _site();
      expect(anime.appliesToVideo(VideoDiscoveryCategory.anime), isTrue);
      expect(anime.appliesToVideo(VideoDiscoveryCategory.movie), isFalse);
      expect(anime.appliesToVideo(null), isTrue);
      expect(_site(enabled: false).appliesToVideo(null), isFalse);
      final RssSearchSiteConfig books = _site(
        domains: <RssSearchDomain>[RssSearchDomain.novel],
      );
      expect(books.appliesToVideo(null), isFalse);
      expect(books.appliesToDiscovery(DiscoveryMediaKind.novel), isTrue);
      expect(books.appliesToDiscovery(DiscoveryMediaKind.manga), isFalse);
      expect(books.videoCategories, isEmpty);
      expect(books.discoveryKinds, <DiscoveryMediaKind>{
        DiscoveryMediaKind.novel,
      });
    });
  });

  group('JSON', () {
    test('往返保真；domains 按枚举序输出', () {
      final RssSearchSiteConfig site = RssSearchSiteConfig(
        id: 'mikan',
        name: 'Mikan',
        urlTemplate: 'https://mikanani.me/RSS/Search?searchstr={query}',
        enabled: false,
        priority: 7,
        domains: <RssSearchDomain>[
          RssSearchDomain.manga,
          RssSearchDomain.anime,
        ],
      );
      final Map<String, Object?> json = site.toJson();
      expect(json['domains'], <String>['anime', 'manga']);
      final RssSearchSiteConfig back = RssSearchSiteConfig.fromJson(json);
      expect(back.toJson(), json);
    });

    test('批量解码：坏行（模板非法 / 非对象）与重复 id 跳过，未知域丢弃', () {
      final List<RssSearchSiteConfig> sites = decodeRssSearchSiteConfigs(
        <Object?>[
          _site().toJson(),
          <String, Object?>{
            'id': 'bad',
            'name': 'Bad',
            'urlTemplate': 'https://x.example/rss',
          },
          'nope',
          _site().toJson(),
          <String, Object?>{
            'id': 'future',
            'name': 'Future',
            'urlTemplate': 'https://f.example/rss?q={query}',
            'domains': <String>['anime', 'music'],
          },
        ],
      );
      expect(sites.map((RssSearchSiteConfig s) => s.id), <String>[
        'nyaa',
        'future',
      ]);
      expect(sites.last.domains, <RssSearchDomain>{RssSearchDomain.anime});
      expect(decodeRssSearchSiteConfigs('not a list'), isEmpty);
      expect(encodeRssSearchSiteConfigs(sites).first, sites.first.toJson());
    });

    test('toString 不泄露模板里的凭据', () {
      final RssSearchSiteConfig site = _site(
        template: 'https://private.example/rss?passkey=SECRET&q={query}',
      );
      expect(site.toString(), isNot(contains('SECRET')));
      expect(site.toString(), contains('private.example'));
    });
  });
}
