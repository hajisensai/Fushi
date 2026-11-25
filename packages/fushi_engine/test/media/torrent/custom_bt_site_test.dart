// 用户导入的 BT 站解析规则：规则解析与校验、windows-1251 编解码、按规则验证站点
// （成功 / 请求失败 / 一行没匹配）、搜索与解析（行内磁链、详情页、带 Cookie 下种子）、
// Cookie 不外发、域门控与持久化往返。全程 MockClient，不碰网络。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_legacy_migration.dart';
import 'package:fushi_engine/media/torrent/bt_site_parser_rule.dart';
import 'package:fushi_engine/media/torrent/bt_site_probe.dart';
import 'package:fushi_engine/media/torrent/bt_site_providers.dart';
import 'package:fushi_engine/media/torrent/custom_bt_site.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 论坛式私有站（windows-1251、分类参数、列表行没有磁链，要进详情页取种子）。
const Map<String, Object?> _forumRule = <String, Object?>{
  'fushiBtSiteParser': 1,
  'name': 'Forum tracker',
  'encoding': 'windows-1251',
  'search': '/browse.php?s={query}&c={category}',
  'categories': <String, String>{'movie': '1002', 'tv': '1001'},
  'rows': 'table.t_peer tr.bg',
  'fields': <String, Object?>{
    'title': 'td.nam a',
    'details': 'td.nam a@href',
    'size': 'td.s',
    'seeders': 'td.sl_s',
    'leechers': 'td.sl_p',
  },
  'detail': <String, Object?>{
    'torrent': "a[href*='download.php']@href",
    'infoHash': <String, Object?>{
      'selector': 'li.hash',
      'regex': '([0-9A-Fa-f]{40})',
    },
  },
};

const String _hash = '0123456789abcdef0123456789abcdef01234567';

String _forumSearchPage() => '''
<html><body><table class="t_peer">
<tr class="mn"><td>header</td></tr>
<tr class="bg">
  <td class="nam"><a href="/details.php?id=42">Матрица / The Matrix (1999) 1080p</a></td>
  <td class="s">1,37 ГБ</td><td class="sl_s">120</td><td class="sl_p">7</td>
</tr>
<tr class="bg"><td class="nam"></td></tr>
</table></body></html>''';

/// [_torrentBytes] 的真实 v1 info hash（SHA-1 of info 字典）。
const String _forumTorrentHash = 'f1f8e0f23ab55ccac8b08d1a11a41f535c2f60d0';

String _forumDetailPage(String hash) =>
    '''
<html><body><ul><li class="hash">Инфо хеш: ${hash.toUpperCase()}</li></ul>
<a href="https://dl.forum.example/download.php?id=42">скачать</a></body></html>''';

/// 一个最小合法种子（单文件，1 字节）。
Uint8List _torrentBytes() => Uint8List.fromList(<int>[
  ...latin1.encode('d4:infod6:lengthi1e4:name1:a12:piece lengthi16384e'),
  ...latin1.encode('6:pieces20:'),
  ...List<int>.filled(20, 1),
  ...latin1.encode('ee'),
]);

class _Recorded {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
}

MockClient _forumSite(
  _Recorded rec, {
  int searchStatus = 200,
  bool emptyResults = false,
  String detailHash = _forumTorrentHash,
}) => MockClient((http.Request request) async {
  rec.requests.add(request);
  final Uri url = request.url;
  if (url.host == 'forum.example' && url.path == '/browse.php') {
    if (searchStatus != 200) return http.Response('denied', searchStatus);
    return http.Response.bytes(
      encodeWindows1251(
        emptyResults
            ? '<html><body><p>Ничего не найдено</p></body></html>'
            : _forumSearchPage(),
      ),
      200,
      headers: <String, String>{
        'content-type': 'text/html; charset=windows-1251',
      },
    );
  }
  if (url.host == 'forum.example' && url.path == '/details.php') {
    return http.Response.bytes(
      encodeWindows1251(_forumDetailPage(detailHash)),
      200,
    );
  }
  if (url.host == 'dl.forum.example' && url.path == '/download.php') {
    if (request.headers['Cookie'] != 'uid=1; pass=secret') {
      // 未登录：站点回登录页，不是种子。
      return http.Response('<html>login</html>', 200);
    }
    return http.Response.bytes(_torrentBytes(), 200);
  }
  return http.Response('not found', 404);
});

BtSiteConfig _forumSite0({String cookie = 'uid=1; pass=secret'}) =>
    BtSiteConfig(
      id: 'forum',
      baseUrl: Uri.parse('https://forum.example'),
      format: BtSiteFormat.custom,
      parser: BtSiteParserRule.fromJson(_forumRule),
      cookie: cookie,
      domains: const <BtSiteDomain>{
        BtSiteDomain.anime,
        BtSiteDomain.movie,
        BtSiteDomain.tv,
        BtSiteDomain.manga,
      },
    );

final VideoMediaReference _matrix = VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '603',
  mediaKind: VideoMetadataMediaKind.movie,
  discoveryCategory: VideoDiscoveryCategory.movie,
  title: 'The Matrix',
);

void main() {
  group('BtSiteParserRule', () {
    test('解析字符串简写与对象两种字段写法，往返不丢信息', () {
      final BtSiteParserRule rule = BtSiteParserRule.fromJson(_forumRule);
      expect(rule.encoding, BtSiteParserEncoding.windows1251);
      expect(rule.details?.selector, 'td.nam a');
      expect(rule.details?.attr, 'href');
      expect(rule.detailInfoHash?.regexSource, '([0-9A-Fa-f]{40})');
      expect(rule.hasDetailRoute, isTrue);
      final BtSiteParserRule again = BtSiteParserRule.fromJson(
        rule.toPrettyJson(),
      );
      expect(again.toJson(), rule.toJson());
    });

    test('{category} 决定生效域：只有映射过的视频域', () {
      final BtSiteParserRule rule = BtSiteParserRule.fromJson(_forumRule);
      expect(rule.coversDomain(BtSiteDomain.movie), isTrue);
      expect(rule.coversDomain(BtSiteDomain.tv), isTrue);
      expect(rule.coversDomain(BtSiteDomain.anime), isFalse, reason: '无映射');
      expect(rule.coversDomain(BtSiteDomain.manga), isFalse, reason: '非视频域');
      expect(_forumSite0().effectiveDomains, <BtSiteDomain>{
        BtSiteDomain.movie,
        BtSiteDomain.tv,
      });
    });

    for (final (String label, Map<String, Object?> patch)
        in <(String, Map<String, Object?>)>[
          ('缺版本标记', <String, Object?>{'fushiBtSiteParser': null}),
          ('版本不认识', <String, Object?>{'fushiBtSiteParser': 2}),
          ('搜索路径缺 {query}', <String, Object?>{'search': '/browse.php'}),
          (
            '搜索路径是别的主机',
            <String, Object?>{'search': '//evil.example/?q={query}'},
          ),
          (
            '搜索路径是绝对地址',
            <String, Object?>{'search': 'https://evil.example/?q={query}'},
          ),
          ('{category} 没有映射', <String, Object?>{'categories': null}),
          ('结果行选择器非法', <String, Object?>{'rows': 'tr[['}),
          ('编码不认识', <String, Object?>{'encoding': 'koi8-r'}),
          ('没有任何下载路线', <String, Object?>{'detail': null}),
          (
            '正则非法',
            <String, Object?>{
              'detail': <String, Object?>{
                'infoHash': <String, Object?>{'selector': 'li', 'regex': '(['},
              },
            },
          ),
        ]) {
      test('畸形规则抛 FormatException：$label', () {
        final Map<String, Object?> json = <String, Object?>{
          ..._forumRule,
          ...patch,
        }..removeWhere((String _, Object? v) => v == null);
        expect(
          () => BtSiteParserRule.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('不是 JSON / 不是对象', () {
      expect(
        () => BtSiteParserRule.fromJson('not json'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => BtSiteParserRule.fromJson('[1]'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('编码与数值', () {
    test('windows-1251 编解码与查询词百分号编码', () {
      expect(
        decodeWindows1251(encodeWindows1251('Матрица Ёё №')),
        'Матрица Ёё №',
      );
      expect(
        BtSiteParserEncoding.windows1251.encodeQueryComponent('Матрица 1999'),
        '%CC%E0%F2%F0%E8%F6%E0+1999',
      );
      expect(
        BtSiteParserEncoding.utf8.encodeQueryComponent('a b&c'),
        'a+b%26c',
      );
    });

    test('体积与计数解析（拉丁 / 西里尔单位）', () {
      expect(
        parseBtSiteHumanSize('1,37 ГБ'),
        (1.37 * 1024 * 1024 * 1024).round(),
      );
      expect(parseBtSiteHumanSize('700 MB'), 700 * 1024 * 1024);
      expect(
        parseBtSiteHumanSize('1.5 GiB'),
        (1.5 * 1024 * 1024 * 1024).round(),
      );
      expect(parseBtSiteHumanSize('512 KB'), 512 * 1024);
      expect(parseBtSiteHumanSize('n/a'), isNull);
      expect(parseBtSiteCount(' 1 024 '), 1024);
      expect(parseBtSiteCount('-'), 0);
    });

    test('infoHash 规范化：十六进制 / base32 / 磁链', () {
      expect(normalizeCustomBtSiteInfoHash(_hash.toUpperCase()), _hash);
      // base32 形式（20 字节全 0 → 32 个 A）。
      expect(normalizeCustomBtSiteInfoHash('A' * 32), '0' * 40);
      expect(normalizeCustomBtSiteInfoHash('xyz'), isNull);
      expect(infoHashFromMagnet('magnet:?xt=urn:btih:$_hash&dn=x'), _hash);
    });
  });

  group('按规则验证站点', () {
    test('规则能解析出行 → custom 格式，Cookie 随请求发给站点', () async {
      final _Recorded rec = _Recorded();
      final BtSiteProbeResult result = await probeBtSite(
        'https://forum.example/some/page?x=1',
        client: _forumSite(rec),
        parser: BtSiteParserRule.fromJson(_forumRule),
        cookie: 'uid=1; pass=secret',
      );
      expect(result.format, BtSiteFormat.custom);
      expect(result.baseUrl.toString(), 'https://forum.example');
      expect(rec.requests, hasLength(1), reason: '有规则就不做自动探测');
      final Uri url = rec.requests.single.url;
      expect(url.path, '/browse.php');
      expect(url.query, 's=test&c=1002', reason: '第一个有映射的视频域（movie）');
      expect(rec.requests.single.headers['Cookie'], 'uid=1; pass=secret');

      final BtSiteConfig site = result.applyTo(
        id: 'forum',
        domains: const <BtSiteDomain>{BtSiteDomain.movie},
        cookie: 'uid=1; pass=secret',
      );
      final List<BtSiteConfig> decoded = decodeBtSiteConfigs(
        jsonDecode(encodeBtSiteConfigs(<BtSiteConfig>[site])),
      );
      expect(decoded.single.format, BtSiteFormat.custom);
      expect(decoded.single.parser?.toJson(), site.parser?.toJson());
      expect(decoded.single.cookie, 'uid=1; pass=secret');
    });

    test('搜索页请求失败 → ruleRequestFailed', () async {
      await expectLater(
        probeBtSite(
          'forum.example',
          client: _forumSite(_Recorded(), searchStatus: 403),
          parser: BtSiteParserRule.fromJson(_forumRule),
        ),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.ruleRequestFailed,
          ),
        ),
      );
    });

    test('一行都没解析出来 → ruleMatchedNothing', () async {
      await expectLater(
        probeBtSite(
          'forum.example',
          client: _forumSite(_Recorded(), emptyResults: true),
          parser: BtSiteParserRule.fromJson(_forumRule),
        ),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.ruleMatchedNothing,
          ),
        ),
      );
    });

    test('没给规则时自动探测仍不会得出 custom 格式', () async {
      await expectLater(
        probeBtSite('forum.example', client: _forumSite(_Recorded())),
        throwsA(
          isA<BtSiteProbeException>().having(
            (BtSiteProbeException e) => e.error,
            'error',
            BtSiteProbeError.unrecognized,
          ),
        ),
      );
    });
  });

  test('通用模板：本身是合法规则，照模板结构的页面能解析出行内磁链', () async {
    final BtSiteParserRule rule = BtSiteParserRule.fromJson(
      kBtSiteParserRuleTemplate,
    );
    expect(rule.searchPathFor('a b'), '/search?q=a+b');
    final List<Uri> seen = <Uri>[];
    final BtSiteProbeResult result = await probeBtSite(
      'https://tracker.example',
      parser: rule,
      client: MockClient((http.Request request) async {
        seen.add(request.url);
        return http.Response(
          '<table class="results"><tbody><tr>'
          '<td class="title"><a href="/t/1">Show S01E01 1080p</a></td>'
          '<td><a href="magnet:?xt=urn:btih:$_hash&amp;dn=Show">m</a></td>'
          '<td class="size">1.2 GB</td><td class="seeders">10</td>'
          '<td class="leechers">2</td></tr></tbody></table>',
          200,
          headers: <String, String>{'content-type': 'text/html'},
        );
      }),
    );
    expect(result.format, BtSiteFormat.custom);
    expect(seen.single.path, '/search');
    expect(seen.single.query, 'q=test');
  });

  group('搜索与解析', () {
    test('搜索：cp1251 页面按规则解析；详情页取种子地址，带 Cookie 下载并校验', () async {
      final _Recorded rec = _Recorded();
      final VideoResourceProvider provider = createBtSiteResourceProvider(
        _forumSite0(),
        _forumSite(rec),
      )!;
      expect(provider.id, 'custom:forum');
      expect(provider.categories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      });

      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(VideoResourceSearchRequest(media: _matrix, query: 'Матрица'));
      expect(result.failures, isEmpty);
      expect(
        rec.requests.single.url.query,
        's=%CC%E0%F2%F0%E8%F6%E0&c=1002',
        reason: '查询词按站点编码（windows-1251）编码，分类取电影域',
      );
      final VideoResourceCandidate candidate = result.items.single;
      expect(candidate.title, 'Матрица / The Matrix (1999) 1080p');
      expect(candidate.sizeBytes, (1.37 * 1024 * 1024 * 1024).round());
      expect(candidate.seeders, 120);
      expect(candidate.leechers, 7);
      expect(candidate.resolution, '1080p');
      expect(candidate.detailsUrl, 'https://forum.example/details.php?id=42');
      expect(candidate.magnetUri, isNull);

      final TorrentAddPayload payload = await provider.resolve(candidate);
      expect(payload, isA<TorrentMetainfoPayload>());
      expect(payload.torrentId, _forumTorrentHash);
      final http.BaseRequest download = rec.requests.last;
      expect(download.url.host, 'dl.forum.example');
      expect(
        download.headers['Cookie'],
        'uid=1; pass=secret',
        reason: '下载子域属于同一站点，带登录态',
      );
      provider.close();
    });

    test('Cookie 过期：站点回登录页不会被当成种子', () async {
      final VideoResourceProvider provider = createBtSiteResourceProvider(
        _forumSite0(cookie: 'uid=1; pass=expired'),
        _forumSite(_Recorded()),
      )!;
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(VideoResourceSearchRequest(media: _matrix));
      await expectLater(
        provider.resolve(result.items.single),
        throwsA(isA<FormatException>()),
      );
    });

    test('详情页声明的 infoHash 与种子不符：拒收', () async {
      final VideoResourceProvider provider = createBtSiteResourceProvider(
        _forumSite0(),
        _forumSite(_Recorded(), detailHash: _hash),
      )!;
      final ProviderBatchResult<VideoResourceCandidate> result = await provider
          .search(VideoResourceSearchRequest(media: _matrix));
      await expectLater(
        provider.resolve(result.items.single),
        throwsA(isA<FormatException>()),
      );
    });

    test('行内磁链：直接交磁链；Cookie 不发给别的域，明文链接不请求', () async {
      final BtSiteParserRule rule = BtSiteParserRule.fromJson(<String, Object?>{
        'fushiBtSiteParser': 1,
        'search': '/search?q={query}',
        'rows': 'div.item',
        'fields': <String, Object?>{
          'title': 'h3',
          'magnet': "a[href^='magnet:']@href",
          'details': 'a.d@href',
        },
      });
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final CustomBtSiteClient client = CustomBtSiteClient(
        baseUrl: Uri.parse('https://www.site.example'),
        rule: rule,
        cookie: 'sid=1',
        client: MockClient((http.Request request) async {
          seen.add(request);
          return http.Response(
            '<div class="item"><h3>Show S01E01 720p</h3>'
            '<a class="d" href="https://other.example/x">d</a>'
            '<a href="magnet:?xt=urn:btih:$_hash&dn=Show">m</a></div>'
            '<div class="item"><h3>No route</h3></div>',
            200,
          );
        }),
      );
      expect(
        client.cookieAllowedFor(Uri.parse('https://site.example/a')),
        isTrue,
      );
      expect(
        client.cookieAllowedFor(Uri.parse('https://dl.site.example/a')),
        isTrue,
      );
      expect(
        client.cookieAllowedFor(Uri.parse('https://other.example/a')),
        isFalse,
      );
      expect(
        client.cookieAllowedFor(Uri.parse('https://notsite.example/a')),
        isFalse,
      );

      final List<CustomBtSiteTorrent> rows = await client.search('Show');
      expect(rows, hasLength(1), reason: '没有下载路线的行丢弃');
      expect(rows.single.infoHash, _hash);
      expect(
        seen.single.url.toString(),
        'https://www.site.example/search?q=Show',
      );
      expect(seen.single.headers['Cookie'], 'sid=1');

      final CustomBtSiteVideoResourceProvider provider =
          CustomBtSiteVideoResourceProvider(
            client: client,
            siteId: 's',
            categories: const <VideoDiscoveryCategory>{
              VideoDiscoveryCategory.tv,
            },
          );
      final TorrentAddPayload payload = await provider.resolve(
        CustomBtSiteCandidate(
          torrent: rows.single,
          siteId: 's',
          providerPriority: 400,
        ),
      );
      expect(payload, isA<TorrentMagnetPayload>());
      expect(payload.torrentId, _hash);
      expect(seen, hasLength(1), reason: '有磁链就不再请求');

      await expectLater(
        client.downloadTorrent(Uri.parse('http://site.example/t.torrent')),
        throwsA(isA<ExternalProviderFailure>()),
        reason: '页面里的明文链接不请求',
      );
    });

    test('注册表：custom:<id> 按 id 解析，别家的候选不认', () async {
      final VideoResourceRegistry registry = VideoResourceRegistry(
        await createBtSiteResourceProviders(<BtSiteConfig>[
          _forumSite0(),
        ], () async => _forumSite(_Recorded())),
      );
      expect(isBtSiteProviderId('custom:forum'), isTrue);
      expect(
        legacyBuiltinBtProviderFormat('custom:forum'),
        isNull,
        reason: 'custom 从来不是旧内置源（旧实现在这里空断言崩溃）',
      );
      expect(legacyBuiltinBtProviderFormat('custom'), isNull);
      expect(
        registry
            .resolveProvider(
              'custom:forum',
              category: VideoDiscoveryCategory.movie,
            )
            ?.id,
        'custom:forum',
      );
      expect(
        registry.resolveProvider(
          'custom:forum',
          category: VideoDiscoveryCategory.anime,
        ),
        isNull,
        reason: '规则没有动画分类',
      );
    });

    test('重定向逐跳手动跟：跳到别的域不带 Cookie，站点子域照带，降级明文拒绝', () async {
      final BtSiteParserRule rule = BtSiteParserRule.fromJson(<String, Object?>{
        'fushiBtSiteParser': 1,
        'search': '/search?q={query}',
        'rows': 'div.item',
        'fields': <String, Object?>{
          'title': 'h3',
          'magnet': "a[href^='magnet:']@href",
        },
      });
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final CustomBtSiteClient client = CustomBtSiteClient(
        baseUrl: Uri.parse('https://site.example'),
        rule: rule,
        cookie: 'sid=1',
        client: MockClient((http.Request request) async {
          seen.add(request);
          final Uri url = request.url;
          if (url.host == 'site.example' && url.path == '/search') {
            return http.Response(
              '',
              302,
              headers: <String, String>{
                'location': 'https://dl.site.example/mirror?q=Show',
              },
            );
          }
          if (url.host == 'dl.site.example' && url.path == '/mirror') {
            return http.Response(
              '',
              301,
              headers: <String, String>{'location': 'https://cdn.other/s'},
            );
          }
          if (url.host == 'cdn.other') {
            return http.Response(
              '<div class="item"><h3>Show</h3>'
              '<a href="magnet:?xt=urn:btih:$_hash&dn=Show">m</a></div>',
              200,
            );
          }
          if (url.path == '/t.torrent') {
            return http.Response(
              '',
              302,
              headers: <String, String>{
                'location': 'http://site.example/t.torrent',
              },
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final List<CustomBtSiteTorrent> rows = await client.search('Show');
      expect(rows.single.infoHash, _hash);
      expect(seen.map((http.BaseRequest r) => r.url.toString()), <String>[
        'https://site.example/search?q=Show',
        'https://dl.site.example/mirror?q=Show',
        'https://cdn.other/s',
      ]);
      expect(
        seen.every((http.BaseRequest r) => !r.followRedirects),
        isTrue,
        reason: '重定向不交给底层 HTTP 实现自动跟',
      );
      expect(seen[0].headers['Cookie'], 'sid=1');
      expect(seen[1].headers['Cookie'], 'sid=1', reason: '站点子域照带');
      expect(
        seen[2].headers.containsKey('Cookie'),
        isFalse,
        reason: '跳到别的域拿不到登录态',
      );

      seen.clear();
      await expectLater(
        client.downloadTorrent(Uri.parse('https://site.example/t.torrent')),
        throwsA(isA<ExternalProviderFailure>()),
        reason: '重定向到明文 HTTP 同样被安全闸门拒绝',
      );
      expect(seen, hasLength(1));
    });

    test('重定向成环：超过上限报错而不是无限跟', () async {
      int calls = 0;
      final CustomBtSiteClient client = CustomBtSiteClient(
        baseUrl: Uri.parse('https://site.example'),
        rule: BtSiteParserRule.fromJson(<String, Object?>{
          'fushiBtSiteParser': 1,
          'search': '/search?q={query}',
          'rows': 'div.item',
          'fields': <String, Object?>{
            'title': 'h3',
            'magnet': "a[href^='magnet:']@href",
          },
        }),
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response(
            '',
            302,
            headers: <String, String>{'location': request.url.toString()},
          );
        }),
      );
      await expectLater(
        client.search('x'),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, CustomBtSiteClient.maxRedirects + 1);
    });
  });

  test('配置：custom 必须带规则，别的格式不能带；Cookie 不能换行', () {
    expect(
      () => BtSiteConfig(
        id: 'x',
        baseUrl: Uri.parse('https://a.example'),
        format: BtSiteFormat.custom,
      ),
      throwsArgumentError,
    );
    expect(
      () => BtSiteConfig(
        id: 'x',
        baseUrl: Uri.parse('https://a.example'),
        format: BtSiteFormat.nyaa,
        parser: BtSiteParserRule.fromJson(_forumRule),
      ),
      throwsArgumentError,
    );
    expect(() => _forumSite0(cookie: 'a=1\r\nX-Evil: 1'), throwsArgumentError);
  });

  test('copyWith：custom 改成别的格式时丢掉规则；custom 内保留 / 替换规则', () {
    final BtSiteConfig custom = _forumSite0();
    final BtSiteConfig nyaa = custom.copyWith(
      format: BtSiteFormat.nyaa,
      cookie: '',
    );
    expect(nyaa.format, BtSiteFormat.nyaa);
    expect(nyaa.parser, isNull, reason: '规则只属于 custom，改格式不能沿用');

    expect(custom.copyWith(enabled: false).parser, same(custom.parser));
    final BtSiteParserRule replaced = BtSiteParserRule.fromJson(
      <String, Object?>{..._forumRule, 'name': 'Other'},
    );
    expect(custom.copyWith(parser: replaced).parser, same(replaced));

    expect(
      nyaa.copyWith(format: BtSiteFormat.custom, parser: replaced).parser,
      same(replaced),
    );
    expect(
      () => nyaa.copyWith(format: BtSiteFormat.custom),
      throwsArgumentError,
      reason: '改回 custom 必须给规则',
    );
    expect(
      () => nyaa.copyWith(parser: replaced),
      throwsArgumentError,
      reason: '非 custom 显式给规则仍交构造器拒绝',
    );
  });
}
