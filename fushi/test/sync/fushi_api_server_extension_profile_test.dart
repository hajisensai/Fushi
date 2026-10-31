// 反馈 biLEesNqWb：浏览器扩展里选 Fushi 配置（Profile），只影响扩展。
//
// 契约（真实 HTTP 层）：
// - POST /api/extension/profiles → {profiles:[{id,name}], activeProfileId}；未注入 404。
// - 「按配置生效」端点（查词 / 制卡 / 查重 / 单词音频 / 在 Anki 中打开）一律经
//   resolveScope 解析出这次请求的服务组：解析出非激活配置时整条请求（查词服务、制卡服务、
//   随响应下发的弹窗设置）都走那一组，激活配置 / 无选择时走 server 默认组——没有混搭。
// - 带请求头时响应头回报实际生效的配置；所选配置已删时回 x-fushi-profile-missing，请求按
//   回退配置照常处理。不带头时不加任何响应头（与本功能引入前一致）。
// - 与配置无关的端点（探活等）不解析配置。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

/// 每条请求实际由哪一组服务处理：`<组名>:<动作>`。
final List<String> _served = <String>[];

/// 一组按某份配置读设置的查词 + 制卡服务（[tag] 标明是哪一组）。
class _TaggedServices
    implements
        FushiRemoteLookupService,
        FushiRemotePopupLookupService,
        FushiRemoteMiningService {
  _TaggedServices(this.tag);

  final String tag;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    _served.add('$tag:lookup');
    return DictionarySearchResult(searchTerm: term)..popupJson = '{}';
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    _served.add('$tag:lookup');
    return const RemoteDictionaryPopupLookup(popupJson: '{}', bestLength: 1);
  }

  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    _served.add('$tag:mine');
    return const RemoteMineResult(result: 'success');
  }

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    _served.add('$tag:duplicate');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// app 侧解析的替身：1 = 激活配置（默认组），2 = 另一份配置（B 组），其余 = 已删。
class _FakeProfileApi implements ExtensionProfileApi {
  final _TaggedServices profileB = _TaggedServices('B');
  final List<int?> resolved = <int?>[];

  @override
  Future<ExtensionProfileList> listProfiles() async =>
      const ExtensionProfileList(
        profiles: <ExtensionProfileSummary>[
          ExtensionProfileSummary(id: 1, name: '默认'),
          ExtensionProfileSummary(id: 2, name: '英语'),
        ],
        activeProfileId: 1,
      );

  @override
  Future<ExtensionProfileScope> resolveScope(int? requestedProfileId) async {
    resolved.add(requestedProfileId);
    if (requestedProfileId == 2) {
      return ExtensionProfileScope(
        effectiveProfileId: 2,
        services: ExtensionRequestServices(
          lookup: profileB,
          mining: profileB,
          autoReadOnLookupProvider: () => true,
        ),
      );
    }
    final bool missing = requestedProfileId != null && requestedProfileId != 1;
    return ExtensionProfileScope(
      effectiveProfileId: 1,
      missingRequestedProfileId: missing ? requestedProfileId : null,
    );
  }
}

Future<List<List<TokenizedSegment>>> _noopTokenize(List<String> texts) async =>
    <List<TokenizedSegment>>[
      for (final String _ in texts) <TokenizedSegment>[],
    ];

void main() {
  late FushiApiServer server;
  late _FakeProfileApi profiles;

  Future<void> startServer({bool withProfileApi = true}) async {
    _served.clear();
    profiles = _FakeProfileApi();
    final _TaggedServices defaults = _TaggedServices('default');
    server = FushiApiServer(
      port: 0,
      lookupService: defaults,
      miningService: defaults,
      tokenizer: _noopTokenize,
      autoReadOnLookupProvider: () => false,
      profileApi: withProfileApi ? profiles : null,
    );
    await server.start();
  }

  /// POST [path]，[profileHeader] 非 null 时带扩展所选配置的请求头；返回状态码、两个配置
  /// 响应头与 JSON 体（读完即关）。
  Future<
    ({int status, String? active, String? missing, Map<String, dynamic>? body})
  >
  post(String path, Map<String, dynamic> body, {String? profileHeader}) async {
    final HttpClient client = HttpClient();
    addTearDown(client.close);
    final HttpClientRequest req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    req.headers.contentType = ContentType.json;
    if (profileHeader != null) {
      req.headers.set('X-Fushi-Profile-Id', profileHeader);
    }
    req.write(jsonEncode(body));
    final HttpClientResponse resp = await req.close();
    final String text = await resp.transform(utf8.decoder).join();
    // 404 等错误响应是纯文本（`Unknown endpoint`），只有 JSON 响应才解析。
    final bool isJson =
        resp.headers.contentType?.mimeType == ContentType.json.mimeType;
    final Object? decoded = isJson ? jsonDecode(text) : null;
    return (
      status: resp.statusCode,
      active: resp.headers.value(kExtensionProfileActiveHeader),
      missing: resp.headers.value(kExtensionProfileMissingHeader),
      body: decoded is Map<String, dynamic> ? decoded : null,
    );
  }

  const Map<String, dynamic> lookupBody = <String, dynamic>{
    'term': '猫',
    'popupOnly': true,
  };

  tearDown(() async => server.stop());

  test('/api/extension/profiles lists profiles and the active one', () async {
    await startServer();
    final r = await post(kExtensionProfilesPath, <String, dynamic>{});
    expect(r.status, 200);
    expect(r.body, <String, dynamic>{
      'profiles': <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'name': '默认'},
        <String, dynamic>{'id': 2, 'name': '英语'},
      ],
      'activeProfileId': 1,
    });
  });

  test(
    '/api/extension/profiles is 404 when the app did not inject it',
    () async {
      await startServer(withProfileApi: false);
      final r = await post(kExtensionProfilesPath, <String, dynamic>{});
      expect(r.status, 404);
    },
  );

  test('selected non-active profile: lookup + popup settings come from its '
      'services group only', () async {
    await startServer();
    final r = await post(
      '/api/lookup/dictionary',
      lookupBody,
      profileHeader: '2',
    );
    expect(r.status, 200);
    expect(r.active, '2');
    expect(r.missing, isNull);
    expect(_served, <String>['B:lookup']);
    expect(
      r.body?['autoReadOnLookup'],
      isTrue,
      reason: '弹窗设置也必须取所选配置那一组（默认组是 false）',
    );
  });

  test('mine and duplicate run on the selected profile group', () async {
    await startServer();
    await post('/api/mine', <String, dynamic>{
      'fields': <String, String>{'expression': '猫'},
      'sentence': '猫がいる',
    }, profileHeader: '2');
    await post('/api/duplicate', <String, dynamic>{
      'expression': '猫',
      'reading': 'ねこ',
    }, profileHeader: '2');
    expect(_served, <String>['B:mine', 'B:duplicate']);
    expect(profiles.resolved, <int?>[2, 2]);
  });

  test(
    'deleted profile: served by the fallback group, missing header set',
    () async {
      await startServer();
      final r = await post(
        '/api/lookup/dictionary',
        lookupBody,
        profileHeader: '9',
      );
      expect(r.status, 200);
      expect(r.missing, '9');
      expect(r.active, '1');
      expect(_served, <String>['default:lookup']);
    },
  );

  test('no header: default group, no profile response headers', () async {
    await startServer();
    final r = await post('/api/lookup/dictionary', lookupBody);
    expect(r.status, 200);
    expect(r.active, isNull);
    expect(r.missing, isNull);
    expect(r.body?['autoReadOnLookup'], isFalse);
    expect(_served, <String>['default:lookup']);
    // 无选择仍要解析一次：「浏览器」媒体类型绑定由 app 侧在这里生效。
    expect(profiles.resolved, <int?>[null]);
  });

  test('garbage header value is treated like no header', () async {
    await startServer();
    for (final String raw in <String>['abc', '0', '-3']) {
      final r = await post(
        '/api/lookup/dictionary',
        lookupBody,
        profileHeader: raw,
      );
      expect(r.status, 200);
      expect(r.active, isNull);
    }
    expect(profiles.resolved, <int?>[null, null, null]);
    expect(_served, everyElement('default:lookup'));
  });

  test('without an injected profile api the header is ignored', () async {
    await startServer(withProfileApi: false);
    final r = await post(
      '/api/lookup/dictionary',
      lookupBody,
      profileHeader: '2',
    );
    expect(r.active, isNull);
    expect(_served, <String>['default:lookup']);
  });

  test('profile-independent endpoints do not resolve a profile', () async {
    await startServer();
    final r = await post(
      '/api/extension/status',
      <String, dynamic>{},
      profileHeader: '2',
    );
    expect(r.status, 200);
    expect(r.active, isNull);
    expect(profiles.resolved, isEmpty);
  });

  test('parseExtensionProfileHeader accepts only positive integers', () {
    expect(parseExtensionProfileHeader('5'), 5);
    expect(parseExtensionProfileHeader(' 12 '), 12);
    expect(parseExtensionProfileHeader(null), isNull);
    expect(parseExtensionProfileHeader(''), isNull);
    expect(parseExtensionProfileHeader('0'), isNull);
    expect(parseExtensionProfileHeader('x'), isNull);
  });
}
