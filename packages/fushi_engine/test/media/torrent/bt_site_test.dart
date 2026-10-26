// 用户 BT 站：自动探测（三种格式 / 无法识别 / 超时）、Nyaa 式分类下拉解析与域映射、
// 旧内置 provider id 解析到用户站点、provider 注册与域门控。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_probe.dart';
import 'package:fushi_engine/media/torrent/bt_site_providers.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';

/// nyaa 主站搜索页导航栏里的分类下拉（按真实页面结构：子类文本只有短名，完整名在
/// title 属性里）。
const String _mainSiteSelect = '''
<select class="form-control" title="Category" data-width="170px" name="c">
<option value="0_0" title="All categories" selected>All categories</option>
<option value="1_0" title="Anime">Anime</option>
<option value="1_1" title="Anime - AMV">- Anime Music Video</option>
<option value="1_2" title="Anime - English">- English-translated</option>
<option value="1_3" title="Anime - Non-English">- Non-English-translated</option>
<option value="1_4" title="Anime - Raw">- Raw</option>
<option value="2_0" title="Audio">Audio</option>
<option value="2_1" title="Audio - Lossless">- Lossless</option>
<option value="2_2" title="Audio - Lossy">- Lossy</option>
<option value="3_0" title="Literature">Literature</option>
<option value="3_1" title="Literature - English">- English-translated</option>
<option value="3_2" title="Literature - Non-English">- Non-English-translated</option>
<option value="3_3" title="Literature - Raw">- Raw</option>
<option value="4_0" title="Live Action">Live Action</option>
<option value="4_1" title="Live Action - English">- English-translated</option>
<option value="4_2" title="Live Action - Idol/PV">- Idol/Promotional Video</option>
<option value="4_3" title="Live Action - Non-English">- Non-English-translated</option>
<option value="4_4" title="Live Action - Raw">- Raw</option>
<option value="5_0" title="Pictures">Pictures</option>
<option value="5_1" title="Pictures - Graphics">- Graphics</option>
<option value="5_2" title="Pictures - Photos">- Photos</option>
<option value="6_0" title="Software">Software</option>
<option value="6_1" title="Software - Apps">- Applications</option>
<option value="6_2" title="Software - Games">- Games</option>
</select>''';

/// 成人分站的分类下拉（同一套软件、另一套分类号）。
const String _adultSiteSelect = '''
<select class="form-control" title="Category" data-width="170px" name="c">
<option value="0_0" title="All categories" selected>All categories</option>
<option value="1_0" title="Art">Art</option>
<option value="1_1" title="Art - Anime">- Anime</option>
<option value="1_2" title="Art - Doujinshi">- Doujinshi</option>
<option value="1_3" title="Art - Games">- Games</option>
<option value="1_4" title="Art - Manga">- Manga</option>
<option value="1_5" title="Art - Pictures">- Pictures</option>
<option value="2_0" title="Real Life">Real Life</option>
<option value="2_1" title="Real Life - Photobooks and Pictures">- Photobooks and Pictures</option>
<option value="2_2" title="Real Life - Videos">- Videos</option>
</select>''';

String _searchPage(String select, {bool withRow = true}) =>
    '''
<!doctype html><html><body>
<nav><form>$select</form></nav>
${withRow ? '''
<table class="table torrent-list"><tbody>
<tr class="success">
<td><a href="/?c=1_2" title="cat"></a></td>
<td colspan="2"><a href="/view/1" title="[Group] Test - 01 [1080p].mkv">x</a></td>
<td><a href="/download/1.torrent"></a><a href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=x">m</a></td>
<td>1.0 GiB</td><td data-timestamp="1700000000">d</td><td>10</td><td>1</td><td>100</td>
</tr></tbody></table>''' : '<div class="container"><h3>No results found</h3></div>'}
</body></html>''';

/// 假站点：按 host 分派到 Nyaa 式 / apibay 式 / Knaben 式行为，其余 404。
MockClient _fakeSites({
  Map<String, String> nyaaHosts = const <String, String>{},
  Set<String> apibayHosts = const <String>{},
  Set<String> knabenHosts = const <String>{},
  Set<String> hangingHosts = const <String>{},
  List<Uri>? log,
}) => MockClient((http.Request request) async {
  log?.add(request.url);
  final String host = request.url.host;
  if (hangingHosts.contains(host)) {
    return Completer<http.Response>().future;
  }
  if (nyaaHosts.containsKey(host) &&
      request.method == 'GET' &&
      request.url.path == '/') {
    return http.Response.bytes(
      utf8.encode(nyaaHosts[host]!),
      200,
      headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
    );
  }
  if (apibayHosts.contains(host) && request.url.path == '/q.php') {
    return http.Response(
      jsonEncode(<Object?>[
        <String, Object?>{
          'id': '0',
          'name': 'No results returned',
          'info_hash': '0000000000000000000000000000000000000000',
        },
      ]),
      200,
    );
  }
  if (knabenHosts.contains(host) &&
      request.method == 'POST' &&
      request.url.path == '/v1') {
    return http.Response(
      jsonEncode(<String, Object?>{'hits': <Object?>[]}),
      200,
    );
  }
  // 「什么站都不是」：一个普通网页。
  return http.Response('<html><body>hello</body></html>', 200);
});

class _MapPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BtSiteConfig _site(
  String id,
  BtSiteFormat format, {
  Set<BtSiteDomain> domains = const <BtSiteDomain>{BtSiteDomain.anime},
  Map<BtSiteDomain, String> categories = const <BtSiteDomain, String>{
    BtSiteDomain.anime: '1_0',
  },
  bool enabled = true,
}) => BtSiteConfig(
  id: id,
  baseUrl: Uri.parse('https://$id.example'),
  format: format,
  domains: domains,
  nyaaCategories: format == BtSiteFormat.nyaa
      ? categories
      : const <BtSiteDomain, String>{},
  enabled: enabled,
);

Future<VideoResourceRegistry> _registry(List<BtSiteConfig> sites) async =>
    VideoResourceRegistry(
      await createBtSiteResourceProviders(
        sites,
        () async => MockClient((_) async => http.Response('', 500)),
      ),
    );

void main() {
  group('Nyaa 式分类下拉', () {
    test('主站：子类用 title 属性拼出完整名，0_0 丢弃', () {
      final List<NyaaCategoryOption> options = parseNyaaCategoryOptions(
        _searchPage(_mainSiteSelect),
      );
      expect(
        options.first,
        const NyaaCategoryOption(value: '1_0', label: 'Anime'),
      );
      expect(
        options,
        contains(
          const NyaaCategoryOption(value: '6_2', label: 'Software - Games'),
        ),
      );
      expect(options.any((NyaaCategoryOption o) => o.value == '0_0'), isFalse);
    });

    test('没有 title 属性时按分类号的父类拼名', () {
      final List<NyaaCategoryOption> options = parseNyaaCategoryOptions('''
<select name="c"><option value="2_0">Audio</option>
<option value="2_1">- Lossless</option></select>''');
      expect(options, const <NyaaCategoryOption>[
        NyaaCategoryOption(value: '2_0', label: 'Audio'),
        NyaaCategoryOption(value: '2_1', label: 'Audio - Lossless'),
      ]);
    });

    test('主站域映射：动画/小说/有声书/漫画/游戏/电影/剧集', () {
      final Map<BtSiteDomain, String> mapping = mapNyaaCategoriesToDomains(
        parseNyaaCategoryOptions(_searchPage(_mainSiteSelect)),
      );
      expect(mapping, <BtSiteDomain, String>{
        BtSiteDomain.anime: '1_0',
        BtSiteDomain.movie: '4_0',
        BtSiteDomain.tv: '4_0',
        BtSiteDomain.novel: '3_0',
        BtSiteDomain.manga: '3_0',
        BtSiteDomain.audiobook: '2_0',
        BtSiteDomain.game: '6_2',
      });
    });

    test('成人分站：同一软件、另一套分类号；没有对应分类的域不生效', () {
      final Map<BtSiteDomain, String> mapping = mapNyaaCategoriesToDomains(
        parseNyaaCategoryOptions(_searchPage(_adultSiteSelect)),
      );
      expect(mapping, <BtSiteDomain, String>{
        BtSiteDomain.anime: '1_1',
        BtSiteDomain.manga: '1_4',
        BtSiteDomain.game: '1_3',
      });
    });

    test('只有子类没有大类时取第一个子类', () {
      expect(
        mapNyaaCategoriesToDomains(const <NyaaCategoryOption>[
          NyaaCategoryOption(value: '7_1', label: 'Audio - Lossless'),
          NyaaCategoryOption(value: '7_2', label: 'Audio - Lossy'),
        ]),
        <BtSiteDomain, String>{BtSiteDomain.audiobook: '7_1'},
      );
    });

    test('生效域 = 勾选 ∩ 站点确有分类', () {
      final BtSiteConfig site = BtSiteConfig(
        id: 'a',
        baseUrl: Uri.parse('https://a.example'),
        format: BtSiteFormat.nyaa,
        domains: const <BtSiteDomain>{BtSiteDomain.anime, BtSiteDomain.movie},
        nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_1'},
      );
      expect(site.effectiveDomains, <BtSiteDomain>{BtSiteDomain.anime});
      expect(site.effectiveVideoCategories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.anime,
      });
    });
  });

  group('自动探测', () {
    test('Nyaa 式：用户填首页带路径与结尾斜杠 → 记 origin 与分类映射', () async {
      final List<Uri> log = <Uri>[];
      final BtSiteProbeResult result = await probeBtSite(
        'nyaa-like.example/some/page/',
        client: _fakeSites(
          nyaaHosts: <String, String>{
            'nyaa-like.example': _searchPage(_mainSiteSelect),
          },
          log: log,
        ),
      );
      expect(result.format, BtSiteFormat.nyaa);
      expect(result.baseUrl, Uri.parse('https://nyaa-like.example'));
      expect(result.nyaaCategories[BtSiteDomain.game], '6_2');
      expect(
        log.any((Uri u) => u.queryParameters['q'] == kBtSiteProbeQuery),
        isTrue,
      );
    });

    test('Nyaa 式 0 条结果：有分类下拉才认', () async {
      final BtSiteProbeResult result = await probeBtSite(
        'https://empty.example',
        client: _fakeSites(
          nyaaHosts: <String, String>{
            'empty.example': _searchPage(_adultSiteSelect, withRow: false),
          },
        ),
      );
      expect(result.format, BtSiteFormat.nyaa);
      await expectLater(
        probeBtSite(
          'https://plain.example',
          client: _fakeSites(
            nyaaHosts: <String, String>{
              'plain.example': _searchPage('', withRow: false),
            },
          ),
        ),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.unrecognized,
          ),
        ),
      );
    });

    test('apibay 式 JSON 接口', () async {
      final BtSiteProbeResult result = await probeBtSite(
        'https://json-a.example/',
        client: _fakeSites(apibayHosts: <String>{'json-a.example'}),
      );
      expect(result.format, BtSiteFormat.apibay);
      expect(result.baseUrl, Uri.parse('https://json-a.example'));
      expect(result.nyaaCategories, isEmpty);
    });

    test('Knaben 式：首页地址 → 试 api. 子域的 /v1', () async {
      final BtSiteProbeResult result = await probeBtSite(
        'https://json-b.example',
        client: _fakeSites(knabenHosts: <String>{'api.json-b.example'}),
      );
      expect(result.format, BtSiteFormat.knaben);
      expect(result.baseUrl, Uri.parse('https://api.json-b.example/v1'));
    });

    test('什么都不认识 → unrecognized', () async {
      await expectLater(
        probeBtSite('https://blog.example', client: _fakeSites()),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.unrecognized,
          ),
        ),
      );
    });

    test('站点一直不回包 → 总时限内结束并报 timedOut', () async {
      final Stopwatch watch = Stopwatch()..start();
      await expectLater(
        probeBtSite(
          'https://slow.example',
          client: _fakeSites(
            hangingHosts: <String>{'slow.example', 'api.slow.example'},
          ),
          attemptTimeout: const Duration(milliseconds: 200),
          totalTimeout: const Duration(milliseconds: 500),
        ),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.timedOut,
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('地址规范化：非法与明文 HTTP', () {
      expect(
        () => normalizeBtSiteUrl('ftp://x.example'),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.invalidUrl,
          ),
        ),
      );
      expect(
        () => normalizeBtSiteUrl('http://lan.example'),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.insecureHttp,
          ),
        ),
      );
      expect(
        normalizeBtSiteUrl(
          'http://lan.example/?q=1#x',
          allowInsecureHttp: true,
        ),
        Uri.parse('http://lan.example'),
      );
      expect(
        normalizeBtSiteUrl('http://127.0.0.1:9000/'),
        Uri.parse('http://127.0.0.1:9000'),
      );
    });
  });

  group('配置编解码', () {
    test('写入后读回一致；坏条目逐条丢弃', () async {
      final _MapPrefs prefs = _MapPrefs();
      final BtSiteConfig site = BtSiteConfig(
        id: 'bt1',
        name: 'My site',
        baseUrl: Uri.parse('https://a.example'),
        format: BtSiteFormat.nyaa,
        domains: const <BtSiteDomain>{BtSiteDomain.anime, BtSiteDomain.game},
        nyaaCategories: const <BtSiteDomain, String>{
          BtSiteDomain.anime: '1_0',
          BtSiteDomain.game: '6_2',
        },
      );
      await writeBtSiteConfigs(prefs, <BtSiteConfig>[site]);
      final List<Object?> raw =
          jsonDecode(prefs.values[kResourceBtSitesPref]! as String)
              as List<Object?>;
      raw.add(<String, Object?>{'id': 'bad', 'url': 'https://b.example'});
      prefs.values[kResourceBtSitesPref] = jsonEncode(raw);
      final List<BtSiteConfig> read = readBtSiteConfigs(prefs);
      expect(read, hasLength(1));
      expect(read.single.toJson(), site.toJson());
      expect(read.single.displayName, 'My site');
      expect(read.single.providerId, 'nyaa:bt1');
    });

    test('新站点 id 不会与旧内置源实例名相撞', () {
      final String id = newBtSiteId();
      expect(isValidBtSiteId(id), isTrue);
      expect(<String>{
        'nyaa.si',
        'default',
        'apibay.org',
        'knaben.org',
      }, isNot(contains(id)));
    });
  });

  group('provider 注册与域门控', () {
    test('没有站点 → 一个 provider 都没有', () async {
      expect((await _registry(const <BtSiteConfig>[])).providers, isEmpty);
    });

    test('启用站点各注册一个 <format>:<siteId>；停用 / 无生效视频域的不注册', () async {
      final VideoResourceRegistry registry = await _registry(<BtSiteConfig>[
        _site('a', BtSiteFormat.nyaa),
        _site(
          'b',
          BtSiteFormat.apibay,
          domains: const <BtSiteDomain>{BtSiteDomain.movie, BtSiteDomain.anime},
        ),
        _site(
          'c',
          BtSiteFormat.knaben,
          enabled: false,
          domains: const <BtSiteDomain>{BtSiteDomain.tv},
        ),
        // 只勾了发现域：没有视频 provider。
        _site(
          'd',
          BtSiteFormat.nyaa,
          domains: const <BtSiteDomain>{BtSiteDomain.novel},
          categories: const <BtSiteDomain, String>{BtSiteDomain.novel: '3_0'},
        ),
      ]);
      expect(
        registry.providers.map((VideoResourceProvider p) => p.id),
        <String>['nyaa:a', 'apibay:b'],
      );
      expect(registry.providers[0].categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.anime,
      });
      // apibay 式只能搜电影 / 剧集：勾了动画也不进动画域。
      expect(registry.providers[1].categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
      });
      expect(
        videoResourceProviderApplies(
          registry.providers[1],
          VideoDiscoveryCategory.anime,
        ),
        isFalse,
      );
      expect(
        (registry.providers[0] as LabeledVideoResourceProvider).displayName,
        'a.example',
      );
    });

    test('发现域只对 Nyaa 式站点生效', () {
      expect(
        _site(
          'j',
          BtSiteFormat.apibay,
          domains: const <BtSiteDomain>{BtSiteDomain.novel},
        ).effectiveDiscoveryKinds,
        isEmpty,
      );
      expect(
        _site(
          'n',
          BtSiteFormat.nyaa,
          domains: const <BtSiteDomain>{BtSiteDomain.novel},
          categories: const <BtSiteDomain, String>{BtSiteDomain.novel: '3_0'},
        ).effectiveDiscoveryKinds,
        <DiscoveryMediaKind>{DiscoveryMediaKind.novel},
      );
    });
  });

  group('旧 provider id 解析', () {
    test('旧内置 Nyaa id（裸 / nyaa.si / default）→ 第一个启用的同格式、覆盖该域的站点', () async {
      final VideoResourceRegistry registry = await _registry(<BtSiteConfig>[
        _site(
          'movies',
          BtSiteFormat.nyaa,
          domains: const <BtSiteDomain>{BtSiteDomain.movie},
          categories: const <BtSiteDomain, String>{BtSiteDomain.movie: '4_0'},
        ),
        _site('first', BtSiteFormat.nyaa),
        _site('second', BtSiteFormat.nyaa),
      ]);
      for (final String legacy in <String>[
        'nyaa',
        'nyaa:nyaa.si',
        'nyaa:default',
      ]) {
        expect(
          registry
              .resolveProvider(legacy, category: VideoDiscoveryCategory.anime)
              ?.id,
          'nyaa:first',
          reason: legacy,
        );
      }
      // 精确 id 优先。
      expect(
        registry
            .resolveProvider(
              'nyaa:second',
              category: VideoDiscoveryCategory.anime,
            )
            ?.id,
        'nyaa:second',
      );
    });

    test('只有别的格式的站 → null（订阅暂停）', () async {
      final VideoResourceRegistry registry = await _registry(<BtSiteConfig>[
        _site(
          'j',
          BtSiteFormat.apibay,
          domains: const <BtSiteDomain>{BtSiteDomain.movie},
        ),
      ]);
      expect(
        registry.resolveProvider(
          'nyaa:nyaa.si',
          category: VideoDiscoveryCategory.anime,
        ),
        isNull,
      );
      expect(
        registry
            .resolveProvider(
              'apibay:apibay.org',
              category: VideoDiscoveryCategory.movie,
            )
            ?.id,
        'apibay:j',
      );
      expect(isBtSiteProviderId('knaben:knaben.org'), isTrue);
      expect(isBtSiteProviderId('torznab:x'), isFalse);
    });

    test('同格式站点停用 → null；重新启用后恢复', () async {
      final BtSiteConfig site = _site('only', BtSiteFormat.nyaa);
      expect(
        (await _registry(<BtSiteConfig>[
          site.copyWith(enabled: false),
        ])).resolveProvider(
          'nyaa:nyaa.si',
          category: VideoDiscoveryCategory.anime,
        ),
        isNull,
      );
      expect(
        (await _registry(<BtSiteConfig>[site]))
            .resolveProvider(
              'nyaa:nyaa.si',
              category: VideoDiscoveryCategory.anime,
            )
            ?.id,
        'nyaa:only',
      );
    });
  });
}
