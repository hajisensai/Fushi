import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/web_knowledge.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

WebKnowledgeSite _builtin(String id) =>
    kBuiltinWebKnowledgeSites.singleWhere((WebKnowledgeSite s) => s.id == id);

final WebKnowledgeSite _zh = _builtin('wikipedia_zh');
final WebKnowledgeSite _ja = _builtin('wikipedia_ja');
final WebKnowledgeSite _en = _builtin('wikipedia_en');
final WebKnowledgeSite _moegirl = _builtin('moegirl');
final WebKnowledgeSite _ann = _builtin('ann');
final WebKnowledgeSite _tvmaze = _builtin('tvmaze');

/// 假 MediaWiki：按 host + action 分派，记下每个请求供断言。
class _FakeWiki {
  _FakeWiki({
    this.titlesByHost = const <String, List<String>>{},
    this.extracts = const <String, String>{},
    this.parsedHtml = const <String, String>{},
    this.failingHosts = const <String>{},
    this.redirects = const <String, String>{},
    this.searchUrls = true,
  });

  final Map<String, List<String>> titlesByHost;

  /// `host|title` → 正文。
  final Map<String, String> extracts;

  /// `host|title` → action=parse 的 HTML（页面存在但没有 extract 字段）。
  final Map<String, String> parsedHtml;
  final Set<String> failingHosts;

  /// 请求标题 → 重定向后的目标标题。
  final Map<String, String> redirects;

  /// opensearch 是否带第 4 列（条目 URL）。
  final bool searchUrls;
  final List<Uri> requests = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];

  late final MockClient client = MockClient((http.Request request) async {
    requests.add(request.url);
    headers.add(request.headers);
    final String host = request.url.host;
    if (failingHosts.contains(host)) {
      return http.Response('boom', 503);
    }
    final Map<String, String> q = request.url.queryParameters;
    if (q['action'] == 'opensearch') {
      final List<String> titles = (titlesByHost[host] ?? const <String>[])
          .take(int.parse(q['limit']!))
          .toList();
      return _json(<Object?>[
        q['search'],
        titles,
        <String>[for (final String _ in titles) ''],
        if (searchUrls)
          <String>[
            for (final String t in titles)
              'https://$host/entry/${Uri.encodeComponent(t)}',
          ],
      ]);
    }
    if (q['prop'] == 'extracts') {
      final String requested = q['titles']!;
      final String resolved = redirects[requested] ?? requested;
      final String key = '$host|$resolved';
      final String? text = extracts[key];
      final bool exists = text != null || parsedHtml.containsKey(key);
      return _json(<String, Object?>{
        'query': <String, Object?>{
          'pages': <Object?>[
            <String, Object?>{
              'title': resolved,
              if (text != null) 'extract': text,
              if (!exists) 'missing': true,
            },
          ],
        },
      });
    }
    if (q['action'] == 'parse') {
      final String? htmlText = parsedHtml['$host|${q['page']}'];
      return _json(<String, Object?>{
        'parse': <String, Object?>{'title': q['page'], 'text': htmlText},
      });
    }
    return http.Response('unexpected', 400);
  });

  http.Response _json(Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
}

const String _annXml = '''
<ann>
  <anime id="11120" gid="1" type="movie" name="The Disappearance of Haruhi Suzumiya" precision="movie">
    <related-prev rel="sequel of" id="6904"/>
    <info gid="2" type="Main title" lang="EN">The Disappearance of Haruhi Suzumiya</info>
    <info gid="3" type="Alternative title" lang="JA">涼宮ハルヒの消失</info>
    <info gid="4" type="Plot Summary">It is mid-December.</info>
    <info gid="5" type="Vintage">2010-02-06</info>
    <info gid="6" type="Vintage">2010-10-01 (DVD)</info>
  </anime>
  <anime id="6904" gid="7" type="TV" name="The Melancholy of Haruhi Suzumiya" precision="TV">
    <info gid="8" type="Main title" lang="JA">Suzumiya Haruhi no Yūutsu</info>
    <info gid="9" type="Alternative title" lang="EN">The Melancholy of Haruhi Suzumiya</info>
    <info gid="10" type="Vintage">2006-04-02 to 2006-07-02</info>
  </anime>
</ann>''';

const String _tvMazeJson = '''
[
  {"score": 0.9, "show": {"name": "Suzumiya Haruhi no Yuuutsu", "type": "Animation",
    "language": "Japanese", "premiered": "2006-04-02", "ended": "2009-09-11",
    "status": "Ended", "url": "https://www.tvmaze.com/shows/14120/x",
    "summary": "<p>On the first day of <b>high school</b> &amp; more.</p>"}},
  {"score": 0.5, "show": {"name": "Haruhi-chan", "type": "Animation",
    "language": "Japanese", "premiered": null, "ended": null, "status": "Ended",
    "url": "https://www.tvmaze.com/shows/19925/y", "summary": null}}
]''';

void main() {
  // 失败冷却与 ANN 闸门是进程级的：前一个用例的状态不能漏进后面的用例。
  setUp(WebKnowledgeClient.resetFailureCooldowns);

  group('MediaWiki', () {
    test('opensearch → extracts：标题、正文、URL 都来自对应站点', () async {
      final _FakeWiki wiki = _FakeWiki(
        titlesByHost: <String, List<String>>{
          'ja.wikipedia.org': <String>['進撃の巨人', '進撃の巨人 (アニメ)'],
        },
        extracts: <String, String>{
          'ja.wikipedia.org|進撃の巨人': '諫山創による漫画作品。',
          'ja.wikipedia.org|進撃の巨人 (アニメ)': 'テレビアニメ。',
        },
      );
      final WebKnowledgeClient client = WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_ja],
        client: wiki.client,
      );

      final List<WebKnowledgePage> pages = await client.search(
        '進撃の巨人',
        pagesPerSource: 2,
      );

      expect(pages, hasLength(2));
      expect(pages[0].site, _ja);
      expect(pages[0].title, '進撃の巨人');
      expect(pages[0].text, '諫山創による漫画作品。');
      expect(pages[0].isList, isFalse);
      // 用 opensearch 给的条目 URL（各站条目路径不同，不自己拼 /wiki/）。
      expect(
        pages[0].url.toString(),
        'https://ja.wikipedia.org/entry/${Uri.encodeComponent('進撃の巨人')}',
      );

      expect(wiki.requests, hasLength(3));
      for (final Uri uri in wiki.requests) {
        expect(uri.scheme, 'https');
        expect(uri.host, 'ja.wikipedia.org');
        expect(uri.path, '/w/api.php');
        expect(uri.queryParameters['format'], 'json');
      }
      final Map<String, String> search = wiki.requests.first.queryParameters;
      expect(search['action'], 'opensearch');
      expect(search['search'], '進撃の巨人');
      expect(search['limit'], '2');
      expect(search['namespace'], '0');
      final Map<String, String> extract = wiki.requests[1].queryParameters;
      expect(extract['action'], 'query');
      expect(extract['prop'], 'extracts');
      expect(extract['explaintext'], '1');
      expect(extract['redirects'], '1');
      expect(extract['titles'], '進撃の巨人');
    });

    test('萌娘百科 / 自定义站点按各自 endpoint 请求', () async {
      final WebKnowledgeSite fandom = WebKnowledgeSite.custom(
        id: 'custom:1',
        label: 'OP',
        endpoint: 'https://onepiece.fandom.com/api.php',
      )!;
      final _FakeWiki wiki = _FakeWiki(
        titlesByHost: <String, List<String>>{
          'zh.moegirl.org.cn': <String>['哆啦A梦'],
          'onepiece.fandom.com': <String>['Luffy'],
        },
        extracts: <String, String>{
          'zh.moegirl.org.cn|哆啦A梦': '漫画。',
          'onepiece.fandom.com|Luffy': 'Captain.',
        },
      );
      final List<WebKnowledgePage> pages = await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_moegirl, fandom],
        client: wiki.client,
      ).search('x');
      expect(pages.map((WebKnowledgePage p) => p.site.id), <String>[
        'moegirl',
        'custom:1',
      ]);
      expect(
        wiki.requests.map((Uri u) => '${u.host}${u.path}').toSet(),
        <String>{'zh.moegirl.org.cn/api.php', 'onepiece.fandom.com/api.php'},
      );
    });

    test('页面在但没有 extract（未装 TextExtracts）→ action=parse 取 HTML 剥成文本', () async {
      final WebKnowledgeSite fandom = WebKnowledgeSite.custom(
        id: 'custom:1',
        label: 'OP',
        endpoint: 'https://onepiece.fandom.com/api.php',
      )!;
      final _FakeWiki wiki = _FakeWiki(
        titlesByHost: <String, List<String>>{
          'onepiece.fandom.com': <String>['One Piece Film: Red'],
        },
        // opensearch 不给 URL 列时，按 index.php?title= 拼。
        searchUrls: false,
        parsedHtml: <String, String>{
          'onepiece.fandom.com|One Piece Film: Red':
              '<div><style>.x{color:red}</style><script>alert(1)</script>'
              '<p>A <b>2022</b> film<sup class="reference">[1]</sup>.</p>'
              '<table class="infobox"><tr><th>Release</th><td>2022-08-06</td></tr></table>'
              '<table class="navbox"><tr><td>Films nav junk</td></tr></table>'
              '<span class="mw-editsection">[edit]</span>'
              '<ul><li>Uta</li><li>Luffy</li></ul></div>',
        },
      );
      final List<WebKnowledgePage> pages = await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[fandom],
        client: wiki.client,
      ).search('One Piece Film');
      final String text = pages.single.text;
      expect(text, contains('A 2022 film.'));
      expect(text, contains('Release 2022-08-06'), reason: '信息框保留');
      expect(text, contains('Uta\nLuffy'));
      for (final String junk in <String>[
        'color:red',
        'alert',
        '[1]',
        'nav junk',
        '[edit]',
        '<',
      ]) {
        expect(text, isNot(contains(junk)), reason: junk);
      }
      expect(
        pages.single.url.toString(),
        'https://onepiece.fandom.com/index.php?title=One_Piece_Film%3A_Red',
      );
      final Uri parse = wiki.requests.last;
      expect(parse.queryParameters['action'], 'parse');
      expect(parse.queryParameters['prop'], 'text');
      expect(parse.queryParameters['page'], 'One Piece Film: Red');
    });

    test('重定向改写了标题 → 按 index.php?title= 拼 URL；缺失页跳过', () async {
      final _FakeWiki wiki = _FakeWiki(
        titlesByHost: <String, List<String>>{
          'en.wikipedia.org': <String>['AoT', 'Missing page'],
        },
        extracts: <String, String>{
          'en.wikipedia.org|Attack on Titan': 'Manga series.',
        },
        redirects: <String, String>{'AoT': 'Attack on Titan'},
      );
      final List<WebKnowledgePage> pages = await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_en],
        client: wiki.client,
      ).search('AoT', pagesPerSource: 2);
      expect(pages, hasLength(1));
      expect(pages.single.title, 'Attack on Titan');
      expect(pages.single.url.path, '/w/index.php');
      expect(pages.single.url.queryParameters['title'], 'Attack_on_Titan');
    });

    test('查询串按 URL 规则编码（空格、&、非 ASCII 不会破坏参数）', () async {
      final _FakeWiki wiki = _FakeWiki();
      await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_en],
        client: wiki.client,
      ).search('  Fate/stay night & UBW 命運  ');
      final Uri uri = wiki.requests.single;
      expect(uri.queryParameters['search'], 'Fate/stay night & UBW 命運');
      expect(uri.query, isNot(contains(' ')));
      expect(uri.query, contains('%26'));
    });

    test('正文按 maxCharsPerPage 截断，且不劈开代理对', () async {
      final String long = '${'a' * 9}😀${'b' * 50}';
      final _FakeWiki wiki = _FakeWiki(
        titlesByHost: <String, List<String>>{
          'en.wikipedia.org': <String>['Long'],
        },
        extracts: <String, String>{'en.wikipedia.org|Long': long},
      );
      final WebKnowledgeClient client = WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_en],
        client: wiki.client,
      );
      expect(
        (await client.search('Long', maxCharsPerPage: 20)).single.text,
        long.substring(0, 20),
      );
      expect(
        (await client.search('Long', maxCharsPerPage: 10)).single.text,
        'a' * 9,
      );
    });
  });

  group('Anime News Network', () {
    test('api.xml → 一页逐行清单（类型 / 标题 / 年份 / id），列表页 URL', () async {
      final List<Uri> requests = <Uri>[];
      final WebKnowledgeClient client = WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_ann],
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response.bytes(utf8.encode(_annXml), 200);
        }),
      );
      final List<WebKnowledgePage> pages = await client.search('Haruhi');
      expect(requests.single.host, 'cdn.animenewsnetwork.com');
      expect(requests.single.path, '/encyclopedia/api.xml');
      expect(requests.single.queryParameters['anime'], '~Haruhi');

      final WebKnowledgePage page = pages.single;
      expect(page.isList, isTrue);
      expect(page.site, _ann);
      expect(page.url.host, 'www.animenewsnetwork.com');
      expect(page.url.queryParameters['q'], 'Haruhi');
      final List<String> lines = page.text.split('\n');
      expect(
        lines[0],
        '[movie] The Disappearance of Haruhi Suzumiya / 涼宮ハルヒの消失 (JA)'
        ' — 2010-02-06 — ANN 11120',
      );
      expect(lines[1], '  It is mid-December.');
      expect(
        lines[2],
        '[TV] Suzumiya Haruhi no Yūutsu / The Melancholy of Haruhi Suzumiya (EN)'
        ' — 2006-04-02 to 2006-07-02 — ANN 6904',
      );
    });

    test('只有一部 → URL 指向该作品页；没有结果 → 无页', () {
      final WebKnowledgePage? single = buildAnnListPage(
        _ann,
        'x',
        '<ann><anime id="42" type="OAV" name="X"/></ann>',
      );
      expect(single!.url.path, '/encyclopedia/anime.php');
      expect(single.url.queryParameters['id'], '42');
      expect(single.text, '[OAV] X — ANN 42');
      expect(
        buildAnnListPage(_ann, 'x', '<ann><warning>no result</warning></ann>'),
        isNull,
      );
    });

    test('ANN 请求进程内串行且相邻两次至少隔 1 秒（跨客户端实例）', () async {
      DateTime clock = DateTime(2026, 9, 27, 12);
      final List<Duration> waits = <Duration>[];
      final List<DateTime> sentAt = <DateTime>[];
      WebKnowledgeClient make() => WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_ann],
        now: () => clock,
        delay: (Duration d) async {
          waits.add(d);
          clock = clock.add(d);
        },
        client: MockClient((http.Request request) async {
          sentAt.add(clock);
          clock = clock.add(const Duration(milliseconds: 200));
          return http.Response.bytes(utf8.encode(_annXml), 200);
        }),
      );
      await Future.wait(<Future<List<WebKnowledgePage>>>[
        make().search('a'),
        make().search('b'),
        make().search('c'),
      ]);
      expect(sentAt, hasLength(3));
      for (int i = 1; i < sentAt.length; i++) {
        expect(
          sentAt[i].difference(sentAt[i - 1]),
          greaterThanOrEqualTo(WebKnowledgeClient.annRequestSpacing),
        );
      }
      // 第一次不等；之后每次补足 1 秒减去上一个请求已耗的 200ms。
      expect(waits, <Duration>[
        const Duration(milliseconds: 800),
        const Duration(milliseconds: 800),
      ]);
    });
  });

  group('TVmaze', () {
    test('search/shows → 一页清单，简介去掉 HTML', () async {
      final List<Uri> requests = <Uri>[];
      final List<WebKnowledgePage> pages = await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_tvmaze],
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response.bytes(utf8.encode(_tvMazeJson), 200);
        }),
      ).search('Haruhi');
      expect(
        requests.single.toString(),
        'https://api.tvmaze.com/search/shows?q=Haruhi',
      );
      final WebKnowledgePage page = pages.single;
      expect(page.isList, isTrue);
      expect(page.url.toString(), 'https://www.tvmaze.com/search?q=Haruhi');
      expect(page.text.split('\n'), <String>[
        '[Animation] Suzumiya Haruhi no Yuuutsu — Japanese — '
            '2006-04-02 ~ 2009-09-11 (Ended) — https://www.tvmaze.com/shows/14120/x',
        '  On the first day of high school & more.',
        '[Animation] Haruhi-chan — Japanese — https://www.tvmaze.com/shows/19925/y',
      ]);
    });

    test('空结果 → 无页', () {
      expect(buildTvMazeListPage(_tvmaze, 'x', '[]'), isNull);
    });
  });

  group('多站点', () {
    test('一个站点失败只跳过它；结果按传入的站点顺序排列', () async {
      final _FakeWiki wiki = _FakeWiki(
        titlesByHost: <String, List<String>>{
          'zh.wikipedia.org': <String>['葬送的芙莉莲'],
          'en.wikipedia.org': <String>['Frieren'],
        },
        extracts: <String, String>{
          'zh.wikipedia.org|葬送的芙莉莲': '日本漫画。',
          'en.wikipedia.org|Frieren': 'Japanese manga.',
        },
        failingHosts: <String>{'ja.wikipedia.org'},
      );
      final List<WebKnowledgePage> pages = await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_en, _ja, _zh],
        client: wiki.client,
      ).search('Frieren');
      expect(pages.map((WebKnowledgePage p) => p.site), <WebKnowledgeSite>[
        _en,
        _zh,
      ]);
      // 中文站不传 variant（未核实 TextExtracts 支持，见文件头）。
      for (final Uri uri in wiki.requests) {
        expect(uri.queryParameters.containsKey('variant'), isFalse);
      }
    });

    test('只请求传入的站点；空站点 / 空查询直接返回空', () async {
      final _FakeWiki wiki = _FakeWiki();
      final WebKnowledgeClient zhOnly = WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_zh],
        client: wiki.client,
      );
      expect(zhOnly.isEnabled, isTrue);
      await zhOnly.search('x');
      expect(wiki.requests.map((Uri u) => u.host).toSet(), <String>{
        'zh.wikipedia.org',
      });

      wiki.requests.clear();
      final WebKnowledgeClient none = WebKnowledgeClient(
        sites: const <WebKnowledgeSite>[],
        client: wiki.client,
      );
      expect(none.isEnabled, isFalse);
      expect(await none.search('x'), isEmpty);
      expect(await zhOnly.search('   '), isEmpty);
      expect(wiki.requests, isEmpty);
    });

    test('对外 UA 用 fushiUserAgent', () async {
      final _FakeWiki wiki = _FakeWiki();
      await WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_en],
        client: wiki.client,
      ).search('Frieren');
      expect(
        wiki.headers.single['User-Agent'],
        startsWith('fushi/web-knowledge'),
      );
    });

    test('超出体积上限的响应被放弃而不是整块读入', () async {
      final MockClient huge = MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream _,
      ) async {
        Stream<List<int>> chunks() async* {
          final List<int> chunk = List<int>.filled(1024 * 1024, 0x20);
          for (int i = 0; i < 8; i++) {
            yield chunk;
          }
        }

        return http.StreamedResponse(chunks(), 200);
      });
      expect(
        await WebKnowledgeClient(
          sites: <WebKnowledgeSite>[_en],
          client: huge,
        ).search('x'),
        isEmpty,
      );
    });

    test('请求超过时限 → 这个站点跳过，其它站点照常返回', () async {
      final WebKnowledgeClient client = WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_ja, _en],
        requestTimeout: const Duration(milliseconds: 50),
        client: MockClient((http.Request request) async {
          if (request.url.host.startsWith('ja.')) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          if (request.url.queryParameters['action'] == 'opensearch') {
            return http.Response('["Doraemon",["Doraemon"],[""]]', 200);
          }
          return http.Response(
            '{"query":{"pages":[{"title":"Doraemon","extract":"text"}]}}',
            200,
          );
        }),
      );
      final List<WebKnowledgePage> pages = await client.search('Doraemon');
      expect(pages.map((WebKnowledgePage p) => p.site), <WebKnowledgeSite>[
        _en,
      ]);
    });

    test('站点失败后按 id 冷却：新建的客户端也跳过它，冷却期满再试', () async {
      DateTime clock = DateTime(2026, 9, 27, 12);
      int tvmazeCalls = 0;
      WebKnowledgeClient make() => WebKnowledgeClient(
        sites: <WebKnowledgeSite>[_tvmaze, _en],
        now: () => clock,
        client: MockClient((http.Request request) async {
          if (request.url.host == 'api.tvmaze.com') {
            tvmazeCalls++;
            throw http.ClientException('blocked');
          }
          if (request.url.queryParameters['action'] == 'opensearch') {
            return http.Response('["Doraemon",["Doraemon"],[""]]', 200);
          }
          return http.Response(
            '{"query":{"pages":[{"title":"Doraemon","extract":"text"}]}}',
            200,
          );
        }),
      );
      await make().search('Doraemon');
      expect(tvmazeCalls, 1);
      final List<WebKnowledgePage> second = await make().search('Doraemon');
      expect(tvmazeCalls, 1, reason: '冷却期内不再撞 tvmaze');
      expect(second.single.site, _en);
      clock = clock
          .add(WebKnowledgeClient.failureCooldown)
          .add(const Duration(seconds: 1));
      await make().search('Doraemon');
      expect(tvmazeCalls, 2, reason: '冷却期满重试');
    });
  });

  group('自定义站点校验与编码', () {
    test('endpoint 必须 https + host + 以 api.php 结尾；query 被去掉', () {
      expect(
        validateWebKnowledgeEndpoint(
          ' https://a.fandom.com/api.php?x=1 ',
        ).toString(),
        'https://a.fandom.com/api.php',
      );
      expect(
        validateWebKnowledgeEndpoint('https://wiki.example.org/w/api.php'),
        isNotNull,
      );
      for (final String bad in <String>[
        'http://a.fandom.com/api.php',
        'https:///api.php',
        'https://a.fandom.com/wiki/Main',
        'a.fandom.com/api.php',
        '',
      ]) {
        expect(validateWebKnowledgeEndpoint(bad), isNull, reason: bad);
      }
    });

    test('custom()：id 须带 custom: 前缀；名称空则用 host', () {
      final WebKnowledgeSite site = WebKnowledgeSite.custom(
        id: 'custom:x',
        label: '  ',
        endpoint: 'https://a.fandom.com/api.php',
      )!;
      expect(site.label, 'a.fandom.com');
      expect(site.kind, WebKnowledgeSiteKind.mediaWiki);
      expect(site.builtin, isFalse);
      expect(
        WebKnowledgeSite.custom(
          id: 'wikipedia_zh',
          label: 'x',
          endpoint: 'https://a.fandom.com/api.php',
        ),
        isNull,
      );
    });

    test('JSON 往返；坏条目 / 重复 id / 整体坏值被丢弃', () {
      final List<WebKnowledgeSite> sites = <WebKnowledgeSite>[
        WebKnowledgeSite.custom(
          id: 'custom:1',
          label: 'A',
          endpoint: 'https://a.fandom.com/api.php',
        )!,
        WebKnowledgeSite.custom(
          id: 'custom:2',
          label: 'B',
          endpoint: 'https://b.example.org/w/api.php',
        )!,
      ];
      expect(
        parseWebKnowledgeCustomSites(encodeWebKnowledgeCustomSites(sites)),
        sites,
      );
      final String messy = jsonEncode(<Object?>[
        sites.first.toJson(),
        <String, Object?>{'id': 'custom:1', 'endpoint': 'https://dup/api.php'},
        <String, Object?>{'id': 'custom:3', 'endpoint': 'http://x/api.php'},
        <String, Object?>{'id': 'custom:4'},
        'garbage',
        <String, Object?>{'id': 'nope', 'endpoint': 'https://c.org/api.php'},
      ]);
      expect(parseWebKnowledgeCustomSites(messy), <WebKnowledgeSite>[
        sites.first,
      ]);
      expect(parseWebKnowledgeCustomSites('{not json'), isEmpty);
      expect(parseWebKnowledgeCustomSites(null), isEmpty);
    });

    test('内置站 id 与旧版偏好值逐字相同（已存偏好不用迁移）', () {
      expect(
        kBuiltinWebKnowledgeSites.map((WebKnowledgeSite s) => s.id),
        <String>[
          'wikipedia_zh',
          'wikipedia_ja',
          'wikipedia_en',
          'moegirl',
          'ann',
          'tvmaze',
        ],
      );
    });
  });

  group('偏好', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    Future<PreferencesRepository> reloaded() async {
      final PreferencesRepository fresh = PreferencesRepository(db);
      await fresh.loadFromDb();
      return fresh;
    }

    final WebKnowledgeSite custom = WebKnowledgeSite.custom(
      id: 'custom:1',
      label: 'OP',
      endpoint: 'https://onepiece.fandom.com/api.php',
    )!;

    test('从未写过 = 全部内置站 + 全部自定义站', () async {
      expect(prefs.aiWebKnowledgeSites, kBuiltinWebKnowledgeSites);
      await prefs.setAiWebKnowledgeCustomSites(<WebKnowledgeSite>[custom]);
      expect(prefs.aiWebKnowledgeSites, <WebKnowledgeSite>[
        ...kBuiltinWebKnowledgeSites,
        custom,
      ]);
      expect(
        (await reloaded()).aiWebKnowledgeEnabledSiteIds,
        contains('custom:1'),
      );
    });

    test('旧版 CSV 迁移：没列的维基视为关掉，新增的内置站默认开', () async {
      await db.setPref('ai_web_knowledge_sources', 's:wikipedia_ja');
      final PreferencesRepository fresh = await reloaded();
      expect(
        fresh.aiWebKnowledgeSites.map((WebKnowledgeSite s) => s.id),
        <String>['wikipedia_ja', 'moegirl', 'ann', 'tvmaze'],
      );
    });

    test('落盘记关掉的站：以后新增的内置站对动过开关的用户也默认开', () async {
      await prefs.setAiWebKnowledgeEnabledSiteIds(<String>{'wikipedia_ja'});
      // 模拟一个新版本多出来的内置站：它不在关闭列表里，所以是开的。
      final String disabled =
          prefs.getPref('ai_web_knowledge_disabled_sites') as String;
      expect(disabled.split(','), isNot(contains('some_future_site')));
      expect(disabled.split(','), contains('ann'));
      // 旧键不再写：旧版客户端经同步写回它认识的子集，不会影响新版。
      await db.setPref('ai_web_knowledge_sources', 's:wikipedia_zh');
      final PreferencesRepository fresh = await reloaded();
      expect(
        fresh.aiWebKnowledgeSites.map((WebKnowledgeSite s) => s.id),
        <String>['wikipedia_ja'],
      );
    });

    test('写空集 = 全关，重载后仍是全关（不回落默认）', () async {
      await prefs.setAiWebKnowledgeEnabledSiteIds(<String>{});
      expect(prefs.aiWebKnowledgeSites, isEmpty);
      expect((await reloaded()).aiWebKnowledgeSites, isEmpty);
    });

    test('启用集含自定义 id；写出顺序稳定，已删站点的 id 被清掉', () async {
      await prefs.setAiWebKnowledgeCustomSites(<WebKnowledgeSite>[custom]);
      await prefs.setAiWebKnowledgeEnabledSiteIds(<String>{
        'custom:1',
        'ann',
        'custom:gone',
        'unknown',
      });
      expect(
        prefs.getPref('ai_web_knowledge_disabled_sites'),
        'wikipedia_zh,wikipedia_ja,wikipedia_en,moegirl,tvmaze',
      );
      expect((await reloaded()).aiWebKnowledgeSites, <WebKnowledgeSite>[
        _ann,
        custom,
      ]);
    });
  });

  test('自定义站 id 只收 custom: + 安全字符（带逗号会拆坏开关列表）', () {
    expect(
      WebKnowledgeSite.custom(
        id: 'custom:a,b',
        label: 'x',
        endpoint: 'https://example.org/api.php',
      ),
      isNull,
    );
    expect(
      WebKnowledgeSite.custom(
        id: 'custom:abc_1-2',
        label: 'x',
        endpoint: 'https://example.org/api.php',
      ),
      isNotNull,
    );
  });

  test('不跟重定向：3xx 按该站失败处理（https 不会被 302 到 http 绕过）', () async {
    final List<http.BaseRequest> requests = <http.BaseRequest>[];
    final WebKnowledgeClient client = WebKnowledgeClient(
      sites: <WebKnowledgeSite>[
        WebKnowledgeSite.custom(
          id: 'custom:r',
          label: 'R',
          endpoint: 'https://example.org/api.php',
        )!,
      ],
      client: MockClient((http.Request request) async {
        requests.add(request);
        return http.Response(
          '',
          302,
          headers: <String, String>{'location': 'http://example.org/api.php'},
        );
      }),
    );
    expect(await client.search('x'), isEmpty);
    expect(requests.single.followRedirects, isFalse);
  });
}
