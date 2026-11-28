import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ai/ai_agent_web_search_policy.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/ops/ctl_web_search_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假的 Brave 搜索结果（每条 `{title, url, description}`）。
String _braveBody(List<(String, String, String)> hits) => jsonEncode(
  <String, Object?>{
    'web': <String, Object?>{
      'results': <Map<String, Object?>>[
        for (final (String title, String url, String snippet) in hits)
          <String, Object?>{'title': title, 'url': url, 'description': snippet},
      ],
    },
  },
);

const WebSearchConfig _brave = WebSearchConfig(
  kind: WebSearchKind.brave,
  apiKey: 'k',
);

/// 一套可控的环境：偏好、假后端、假网页、结果缓存（时钟可拨）。
class _Env {
  _Env() {
    cache = WebSearchResultCache(clock: () => now);
    routes = <CtlRoute>[
      for (final FushiOp op in buildWebSearchOpsFor(
        config: () => config,
        consent: () => consent,
        grantConsent: () async {
          grants++;
          consent = kAiAgentWebSearchAllow;
        },
        client: (WebSearchConfig cfg) => WebSearchClient(
          config: cfg,
          client: MockClient((http.Request r) async {
            searchRequests.add(r.url);
            return http.Response(searchBody, 200);
          }),
          pageClient: MockClient((http.Request r) async {
            pageRequests.add(r.url);
            return pages[r.url.toString()] ?? http.Response('not found', 404);
          }),
          resolveHost: (String host) async => <InternetAddress>[
            resolved[host] ?? InternetAddress('93.184.216.34'),
          ],
        ),
        cache: cache,
      ))
        op.route,
    ];
  }

  WebSearchConfig? config = _brave;
  String consent = '';
  int grants = 0;
  DateTime now = DateTime(2026, 11, 20, 12);
  String searchBody = _braveBody(<(String, String, String)>[]);
  final Map<String, http.Response> pages = <String, http.Response>{};
  final Map<String, InternetAddress> resolved = <String, InternetAddress>{};
  final List<Uri> searchRequests = <Uri>[];
  final List<Uri> pageRequests = <Uri>[];
  late final WebSearchResultCache cache;
  late final List<CtlRoute> routes;

  Future<Map<String, Object?>> call(
    String pattern,
    Map<String, Object?> body,
  ) async {
    final CtlRoute route = routes.singleWhere(
      (CtlRoute r) => r.pattern == pattern,
    );
    final Object? result = await route.handler(
      CtlCall(method: route.method, path: pattern, body: body),
    );
    return (result! as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> search(
    String query, {
    bool confirm = false,
    int? limit,
  }) => call(WebSearchOps.search.pattern, <String, Object?>{
    'query': query,
    'limit': ?limit,
    if (confirm) 'confirm': true,
  });

  Future<Map<String, Object?>> read(String id, {int? offset}) => call(
    WebSearchOps.read.pattern,
    <String, Object?>{'id': id, 'offset': ?offset},
  );
}

Matcher _fails(String code) =>
    throwsA(isA<CtlFailure>().having((CtlFailure f) => f.code, 'code', code));

List<Map<String, Object?>> _results(Map<String, Object?> r) =>
    <Map<String, Object?>>[
      for (final Object? row in r['results']! as List<Object?>)
        (row! as Map).cast<String, Object?>(),
    ];

void main() {
  late _Env env;

  setUp(() => env = _Env());

  group('门', () {
    test('没配后端：拒绝，不发任何请求', () async {
      env.config = null;
      await expectLater(
        env.search('x', confirm: true),
        _fails('no_search_backend'),
      );
      await expectLater(env.read('r1'), _fails('no_search_backend'));
      env.config = const WebSearchConfig(kind: WebSearchKind.brave);
      await expectLater(
        env.search('x', confirm: true),
        _fails('no_search_backend'),
      );
      expect(env.searchRequests, isEmpty);
      expect(env.grants, 0);
    });

    test('设置里关了：拒绝，不发请求，也不因 confirm 改回同意', () async {
      env.consent = kAiAgentWebSearchOff;
      await expectLater(
        env.search('x', confirm: true),
        _fails('web_search_off'),
      );
      expect(env.searchRequests, isEmpty);
      expect(env.consent, kAiAgentWebSearchOff);
    });

    test('还没同意：没有 confirm 就拒绝；带 confirm 的那一次记下同意，之后不再要', () async {
      env.searchBody = _braveBody(<(String, String, String)>[
        ('Title', 'https://example.org/a', 'snippet'),
      ]);
      await expectLater(env.search('x'), _fails('consent_required'));
      expect(env.searchRequests, isEmpty);
      expect(env.grants, 0);

      final Map<String, Object?> first = await env.search('x', confirm: true);
      expect(env.grants, 1);
      expect(env.consent, kAiAgentWebSearchAllow);
      expect(_results(first), hasLength(1));

      await env.search('y');
      expect(env.grants, 1, reason: '同意过就不再写');
      expect(env.searchRequests, hasLength(2));
    });
  });

  group('web.search', () {
    setUp(() => env.consent = kAiAgentWebSearchAllow);

    test('发给配置的后端，回 {id, 标题, 摘要, 站点}；内网地址的结果不给', () async {
      env.searchBody = _braveBody(<(String, String, String)>[
        ('Frieren', 'https://wiki.example.org/frieren', 'An anime ' * 60),
        ('Router', 'http://192.168.1.1/admin', 'local'),
        ('Local', 'http://localhost:8080/', 'local'),
      ]);
      final Map<String, Object?> r = await env.search('葬送のフリーレン 放送日');
      final Uri sent = env.searchRequests.single;
      expect(sent.host, 'api.search.brave.com');
      expect(sent.queryParameters['q'], '葬送のフリーレン 放送日');
      expect(r['backend'], 'brave');
      final List<Map<String, Object?>> rows = _results(r);
      expect(rows, hasLength(1));
      expect(
        rows.single.keys,
        containsAll(<String>['id', 'title', 'snippet', 'site']),
      );
      expect(rows.single.containsKey('url'), isFalse);
      expect(rows.single['site'], 'wiki.example.org');
      expect(
        (rows.single['snippet']! as String).length,
        lessThanOrEqualTo(kWebSearchSnippetChars + 1),
      );
      expect(rows.single['id'], matches(RegExp(r'^r[0-9a-f]{12}$')));
    });

    test('条数上限：默认 5，最多 10', () async {
      await env.search('a');
      await env.search('b', limit: 50);
      expect(
        env.searchRequests[0].queryParameters['count'],
        '${WebSearchOps.defaultLimit}',
      );
      expect(
        env.searchRequests[1].queryParameters['count'],
        '${WebSearchOps.maxLimit}',
      );
      await expectLater(env.search('c', limit: 0), _fails('bad_request'));
      await expectLater(env.search('  '), _fails('bad_request'));
    });
  });

  group('web.read', () {
    setUp(() => env.consent = kAiAgentWebSearchAllow);

    Future<String> searchOne(String url) async {
      env.searchBody = _braveBody(<(String, String, String)>[('T', url, 's')]);
      return _results(await env.search('q')).single['id']! as String;
    }

    test('伪造 / 过期的结果 id 被拒，不发请求', () async {
      await expectLater(env.read('rdeadbeef0000'), _fails('not_found'));
      await expectLater(
        env.read('https://evil.example/?leak=1'),
        _fails('not_found'),
      );
      final String id = await searchOne('https://example.org/a');
      env.now = env.now.add(kWebSearchResultTtl + const Duration(minutes: 1));
      await expectLater(env.read(id), _fails('not_found'));
      expect(env.pageRequests, isEmpty);
    });

    test('正文截断成段、offset 取后续段，同一页只抓一次', () async {
      final String id = await searchOne('https://example.org/long');
      final String body = List<String>.generate(
        10000,
        (int i) => 'abcdefghij'[i % 10],
      ).join();
      env.pages['https://example.org/long'] = http.Response(
        '<html><head><title>x</title></head><body><p>$body</p></body></html>',
        200,
      );
      final Map<String, Object?> first = await env.read(id);
      expect((first['text']! as String).length, WebSearchOps.readChunkChars);
      expect(first['offset'], 0);
      expect(first['nextOffset'], WebSearchOps.readChunkChars);
      expect(first['url'], 'https://example.org/long');
      final int total = first['totalChars']! as int;
      expect(total, greaterThanOrEqualTo(10000));

      final Map<String, Object?> last = await env.read(id, offset: 8000);
      expect(last['offset'], 8000);
      expect((last['text']! as String).length, total - 8000);
      expect(last['nextOffset'], isNull);

      final Map<String, Object?> past = await env.read(id, offset: total + 50);
      expect(past['text'], '');
      expect(past['nextOffset'], isNull);
      expect(env.pageRequests, hasLength(1), reason: '分页读缓存，不重抓');
      await expectLater(env.read(id, offset: -1), _fails('bad_request'));
    });

    test('SSRF：结果域名解析到回环 / 内网 → 抓不到，一个请求也不发', () async {
      final String id = await searchOne('https://evil.example/page');
      env.resolved['evil.example'] = InternetAddress.loopbackIPv4;
      await expectLater(env.read(id), _fails('fetch_failed'));
      expect(env.pageRequests, isEmpty);
    });

    test('SSRF：重定向到内网地址 → 停在那一跳，不跟过去', () async {
      final String id = await searchOne('https://example.org/redirect');
      env.pages['https://example.org/redirect'] = http.Response(
        '',
        302,
        headers: <String, String>{'location': 'http://10.0.0.5/secret'},
      );
      await expectLater(env.read(id), _fails('fetch_failed'));
      expect(env.pageRequests.map((Uri u) => u.toString()), <String>[
        'https://example.org/redirect',
      ]);
    });

    test('没同意时读也要 confirm（同一个首次确认）', () async {
      final String id = await searchOne('https://example.org/a');
      env.consent = '';
      await expectLater(env.read(id), _fails('consent_required'));
      expect(env.pageRequests, isEmpty);
    });
  });

  group('描述与 AI 助手的首次确认', () {
    late FushiDatabase db;
    late AiAgentToolbox toolbox;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      env.searchBody = _braveBody(<(String, String, String)>[
        ('T', 'https://example.org/a', 's'),
      ]);
      // 可用性与首次确认由实现按同一份偏好现算（buildWebSearchOpsFor）。
      final OpCatalog catalog = OpCatalog.build(
        env.routes,
        const <OpDescription>[],
      );
      toolbox = AiAgentToolbox(
        invoker: OpInvoker(catalog),
        database: db,
        resident: const <String>[],
      );
    });

    tearDown(() => db.close());

    AgentToolInvocation invocation(
      String name,
      Map<String, Object?> args, {
      bool confirmed = false,
    }) => AgentToolInvocation(
      sessionId: 's',
      name: name,
      arguments: args,
      confirmed: confirmed,
    );

    test('两条都是 irreversible；参数是搜索词 / 结果 id，没有地址类参数', () {
      for (final String id in <String>['web.search', 'web.read']) {
        final FushiOp op = toolbox.catalog[id]!;
        expect(op.risk, OpRisk.irreversible, reason: id);
        expect(
          op.spec.needsConfirmation,
          isTrue,
          reason: '$id：静态描述仍要确认（MCP / 远端宿主逐次确认）',
        );
        expect(
          op.spec.modelParams.map((OpParam p) => p.name),
          everyElement(
            isNot(
              matches(
                RegExp(
                  r'(url|uri|link|endpoint|href|host|address)s?$',
                  caseSensitive: false,
                ),
              ),
            ),
          ),
          reason: id,
        );
      }
    });

    test('第一次出确认卡、同意后记住不再问；关掉不可用；再打开重新问', () async {
      // 第一次：要确认卡；没确认执行不了。
      expect(toolbox.describeTool('web.search')!.needsConfirmation, isTrue);
      expect(
        (await toolbox.execute(
          invocation('web.search', <String, Object?>{'query': 'q'}),
        )).errorCode,
        'confirmation_required',
      );
      expect(env.searchRequests, isEmpty);
      // 用户点了同意：表态参数注入 → 路由记下同意。
      final AgentToolResult ok = await toolbox.execute(
        invocation('web.search', <String, Object?>{
          'query': 'q',
        }, confirmed: true),
      );
      expect(ok.isError, isFalse);
      expect(env.consent, kAiAgentWebSearchAllow);

      // 之后：两条都不再要确认卡，不确认也能执行（表态参数照「已同意」注入）。
      for (final String id in <String>['web.search', 'web.read']) {
        final AgentToolSpec spec = toolbox.describeTool(id)!;
        expect(spec.preapproved, isTrue, reason: id);
        expect(spec.needsConfirmation, isFalse, reason: id);
      }
      final Map<String, Object?> data = (ok.data! as Map)
          .cast<String, Object?>();
      final String resultId =
          ((data['results']! as List<Object?>).single! as Map)['id']! as String;
      env.pages['https://example.org/a'] = http.Response('<p>hello</p>', 200);
      final AgentToolResult read = await toolbox.execute(
        invocation('web.read', <String, Object?>{'id': resultId}),
      );
      expect(read.isError, isFalse, reason: read.errorMessage);
      expect(((read.data! as Map)['text']! as String), contains('hello'));
      expect(env.grants, 1);

      // 设置里关掉：清单里藏起来、按名字也调不动。
      env.consent = kAiAgentWebSearchOff;
      expect(toolbox.describeTool('web.search'), isNull);
      expect(
        (await toolbox.execute(
          invocation('web.search', <String, Object?>{'query': 'q'}),
        )).errorCode,
        'rejected',
      );

      // 再打开（回到「还没同意」）：重新要确认卡。
      env.consent = '';
      expect(toolbox.describeTool('web.search')!.needsConfirmation, isTrue);
      expect(toolbox.describeTool('web.read')!.preapproved, isFalse);
    });

    test('system prompt 那一句只在能用时出现', () {
      expect(toolbox.promptNote(), contains('web__search'));
      env.config = null;
      expect(toolbox.promptNote(), isNull);
      env.config = _brave;
      env.consent = kAiAgentWebSearchOff;
      expect(toolbox.promptNote(), isNull);
    });

    test('确认卡的后端名：Brave / SearXNG 带主机名', () {
      expect(webSearchBackendLabel(_brave), 'Brave Search');
      expect(
        webSearchBackendLabel(
          const WebSearchConfig(
            kind: WebSearchKind.searxng,
            endpoint: 'https://searx.example.org',
          ),
        ),
        'SearXNG (searx.example.org)',
      );
      expect(kAgentWebSearchOp.hasMatch('web.search'), isTrue);
      expect(kAgentWebSearchOp.hasMatch('web.read'), isTrue);
      expect(kAgentWebSearchOp.hasMatch('web.open'), isFalse);
    });
  });
}
