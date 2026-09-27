import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/web_knowledge.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假 MediaWiki：按 host + action 分派，记下每个请求供断言。
class _FakeWiki {
  _FakeWiki({
    this.titlesByHost = const <String, List<String>>{},
    this.extracts = const <String, String>{},
    this.failingHosts = const <String>{},
    this.redirects = const <String, String>{},
  });

  final Map<String, List<String>> titlesByHost;

  /// `host|title` → 正文。
  final Map<String, String> extracts;
  final Set<String> failingHosts;

  /// 请求标题 → 重定向后的目标标题。
  final Map<String, String> redirects;
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
    if (q['list'] == 'search') {
      final List<String> titles = titlesByHost[host] ?? const <String>[];
      final int limit = int.parse(q['srlimit']!);
      return _json(<String, Object?>{
        'query': <String, Object?>{
          'search': <Object?>[
            for (final String title in titles.take(limit))
              <String, Object?>{'ns': 0, 'title': title},
          ],
        },
      });
    }
    if (q['prop'] == 'extracts') {
      final String requested = q['titles']!;
      final String resolved = redirects[requested] ?? requested;
      final String? text = extracts['$host|$resolved'];
      return _json(<String, Object?>{
        'query': <String, Object?>{
          'pages': <Object?>[
            <String, Object?>{
              'title': resolved,
              if (text != null) 'extract': text else 'missing': true,
            },
          ],
        },
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

void main() {
  test('search → extract：标题、正文、URL 都来自对应语言站', () async {
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
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaJa},
      client: wiki.client,
    );

    final List<WebKnowledgePage> pages = await client.search(
      '進撃の巨人',
      pagesPerSource: 2,
    );

    expect(pages, hasLength(2));
    expect(pages[0].source, WebKnowledgeSource.wikipediaJa);
    expect(pages[0].title, '進撃の巨人');
    expect(pages[0].text, '諫山創による漫画作品。');
    expect(
      pages[0].url.toString(),
      Uri.https('ja.wikipedia.org', '/wiki/進撃の巨人').toString(),
    );
    // 空格按维基惯例写成下划线。
    expect(Uri.decodeComponent(pages[1].url.path), '/wiki/進撃の巨人_(アニメ)');

    // 一次搜索 + 两次取正文，全部打 ja 站的 api.php。
    expect(wiki.requests, hasLength(3));
    for (final Uri uri in wiki.requests) {
      expect(uri.scheme, 'https');
      expect(uri.host, 'ja.wikipedia.org');
      expect(uri.path, '/w/api.php');
      expect(uri.queryParameters['format'], 'json');
      expect(uri.queryParameters['formatversion'], '2');
    }
    final Map<String, String> search = wiki.requests.first.queryParameters;
    expect(search['action'], 'query');
    expect(search['list'], 'search');
    expect(search['srsearch'], '進撃の巨人');
    expect(search['srlimit'], '2');
    final Map<String, String> extract = wiki.requests[1].queryParameters;
    expect(extract['prop'], 'extracts');
    expect(extract['explaintext'], '1');
    expect(extract['redirects'], '1');
    expect(extract['titles'], '進撃の巨人');
  });

  test('对外 UA 用 fushiUserAgent 且不带旧名', () async {
    final _FakeWiki wiki = _FakeWiki();
    final WebKnowledgeClient client = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaEn},
      client: wiki.client,
    );
    await client.search('Frieren');
    expect(
      wiki.headers.single['User-Agent'],
      startsWith('fushi/web-knowledge'),
    );
  });

  test('查询串按 URL 规则编码（空格、&、非 ASCII 不会破坏参数）', () async {
    final _FakeWiki wiki = _FakeWiki();
    final WebKnowledgeClient client = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaEn},
      client: wiki.client,
    );
    await client.search('  Fate/stay night & UBW 命運  ');
    final Uri uri = wiki.requests.single;
    expect(uri.queryParameters['srsearch'], 'Fate/stay night & UBW 命運');
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
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaEn},
      client: wiki.client,
    );

    List<WebKnowledgePage> pages = await client.search(
      'Long',
      maxCharsPerPage: 20,
    );
    expect(pages.single.text, long.substring(0, 20));

    // 第 10 个码元是 emoji 的高位代理：截到 10 会劈开，必须退一格。
    pages = await client.search('Long', maxCharsPerPage: 10);
    expect(pages.single.text, 'a' * 9);
  });

  test('一个来源失败只跳过它，其它来源照常返回；结果按枚举顺序排列', () async {
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
    final WebKnowledgeClient client = WebKnowledgeClient(
      sources: WebKnowledgeSource.values.toSet(),
      client: wiki.client,
    );

    final List<WebKnowledgePage> pages = await client.search('Frieren');

    expect(pages.map((WebKnowledgePage p) => p.source), <WebKnowledgeSource>[
      WebKnowledgeSource.wikipediaZh,
      WebKnowledgeSource.wikipediaEn,
    ]);
    expect(pages[0].url.host, 'zh.wikipedia.org');
    expect(pages[1].url.host, 'en.wikipedia.org');
    // 中文站不传 variant（未核实 TextExtracts 支持，见文件头）。
    for (final Uri uri in wiki.requests) {
      expect(uri.queryParameters.containsKey('variant'), isFalse);
    }
  });

  test('未启用的来源不发请求；空来源 / 空查询直接返回空', () async {
    final _FakeWiki wiki = _FakeWiki();
    final WebKnowledgeClient zhOnly = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaZh},
      client: wiki.client,
    );
    expect(zhOnly.isEnabled, isTrue);
    await zhOnly.search('x');
    expect(wiki.requests.map((Uri u) => u.host).toSet(), <String>{
      'zh.wikipedia.org',
    });

    wiki.requests.clear();
    final WebKnowledgeClient none = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{},
      client: wiki.client,
    );
    expect(none.isEnabled, isFalse);
    expect(await none.search('x'), isEmpty);
    expect(await zhOnly.search('   '), isEmpty);
    expect(wiki.requests, isEmpty);
  });

  test('重定向后以目标页标题建 URL；缺正文的页被跳过', () async {
    final _FakeWiki wiki = _FakeWiki(
      titlesByHost: <String, List<String>>{
        'en.wikipedia.org': <String>['AoT', 'Missing page'],
      },
      extracts: <String, String>{
        'en.wikipedia.org|Attack on Titan': 'Manga series.',
      },
      redirects: <String, String>{'AoT': 'Attack on Titan'},
    );
    final WebKnowledgeClient client = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaEn},
      client: wiki.client,
    );

    final List<WebKnowledgePage> pages = await client.search(
      'AoT',
      pagesPerSource: 2,
    );
    expect(pages, hasLength(1));
    expect(pages.single.title, 'Attack on Titan');
    expect(pages.single.url.path, '/wiki/Attack_on_Titan');
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
    final WebKnowledgeClient client = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{WebKnowledgeSource.wikipediaEn},
      client: huge,
    );
    expect(await client.search('x'), isEmpty);
  });

  test('storageKey 往返与解析', () {
    for (final WebKnowledgeSource s in WebKnowledgeSource.values) {
      expect(WebKnowledgeSource.fromStorageKey(s.storageKey), s);
    }
    expect(WebKnowledgeSource.fromStorageKey(null), isNull);
    expect(WebKnowledgeSource.fromStorageKey('bogus'), isNull);
    expect(parseWebKnowledgeSources(null), WebKnowledgeSource.values.toSet());
    expect(parseWebKnowledgeSources(''), isEmpty);
    expect(
      parseWebKnowledgeSources('wikipedia_en,unknown, wikipedia_zh'),
      <WebKnowledgeSource>{
        WebKnowledgeSource.wikipediaEn,
        WebKnowledgeSource.wikipediaZh,
      },
    );
    // 编码按枚举顺序，与集合插入顺序无关。
    expect(
      encodeWebKnowledgeSources(<WebKnowledgeSource>{
        WebKnowledgeSource.wikipediaEn,
        WebKnowledgeSource.wikipediaZh,
      }),
      'wikipedia_zh,wikipedia_en',
    );
  });

  group('偏好 ai_web_knowledge_sources', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    Future<Set<WebKnowledgeSource>> reloaded() async {
      final PreferencesRepository fresh = PreferencesRepository(db);
      await fresh.loadFromDb();
      return fresh.aiWebKnowledgeSources;
    }

    test('从未写过 = 默认全开', () async {
      expect(prefs.aiWebKnowledgeSources, WebKnowledgeSource.values.toSet());
      expect(await reloaded(), WebKnowledgeSource.values.toSet());
    });

    test('写空集 = 全关，且重载后仍是全关（不回落默认）', () async {
      await prefs.setAiWebKnowledgeSources(<WebKnowledgeSource>{});
      expect(prefs.aiWebKnowledgeSources, isEmpty);
      expect(await reloaded(), isEmpty);
    });

    test('子集往返', () async {
      final Set<WebKnowledgeSource> subset = <WebKnowledgeSource>{
        WebKnowledgeSource.wikipediaJa,
      };
      await prefs.setAiWebKnowledgeSources(subset);
      expect(prefs.aiWebKnowledgeSources, subset);
      expect(await reloaded(), subset);
    });
  });

  test('请求超过时限 → 这个来源跳过，其它来源照常返回', () async {
    final WebKnowledgeClient client = WebKnowledgeClient(
      sources: <WebKnowledgeSource>{
        WebKnowledgeSource.wikipediaJa,
        WebKnowledgeSource.wikipediaEn,
      },
      requestTimeout: const Duration(milliseconds: 50),
      client: MockClient((http.Request request) async {
        if (request.url.host.startsWith('ja.')) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (request.url.queryParameters['list'] == 'search') {
          return http.Response(
            '{"query":{"search":[{"title":"Doraemon"}]}}',
            200,
          );
        }
        return http.Response(
          '{"query":{"pages":[{"title":"Doraemon","extract":"text"}]}}',
          200,
        );
      }),
    );
    final List<WebKnowledgePage> pages = await client.search('Doraemon');
    expect(pages.map((WebKnowledgePage p) => p.source), <WebKnowledgeSource>[
      WebKnowledgeSource.wikipediaEn,
    ]);
  });
}
