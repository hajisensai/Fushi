// 反馈 biLEesNqWb：浏览器扩展里手动切换 Fushi 配置（Profile）。
//
// 契约（真实 HTTP 层）：
// - POST /api/extension/profiles → {profiles:[{id,name}], activeProfileId}；未注入 404。
// - 查词 / 制卡等「按配置生效」端点带 x-fushi-profile-id 时，server 先 await app 让所选配置
//   生效、再进 handler（顺序钉死：否则第一条请求按旧配置处理）；响应头回报实际生效的配置，
//   所选配置已删时回 x-fushi-profile-missing（请求照常处理）。
// - 显式选择压过「浏览器」媒体类型绑定：带头时不再触发 onLookupActivity。
// - 不带头 / 非按配置端点：行为与之前一致（不调 applySelectedProfile）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

/// 事件序列：断言「先切配置、后处理请求」。
final List<String> _events = <String>[];

class _FakeLookup
    implements FushiRemoteLookupService, FushiRemotePopupLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    _events.add('lookup:$term');
    return DictionarySearchResult(searchTerm: term)..popupJson = '{}';
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    _events.add('lookup:$term');
    return const RemoteDictionaryPopupLookup(popupJson: '{}', bestLength: 1);
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

class _FakeMining implements FushiRemoteMiningService {
  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    _events.add('mine');
    return const RemoteMineResult(result: 'success');
  }

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    _events.add('duplicate');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileApi implements ExtensionProfileApi {
  _FakeProfileApi({required this.existing, required this.activeProfileId});

  final Map<int, String> existing;
  int activeProfileId;
  final List<int> applied = <int>[];

  @override
  Future<ExtensionProfileList> listProfiles() async => ExtensionProfileList(
    profiles: <ExtensionProfileSummary>[
      for (final MapEntry<int, String> e in existing.entries)
        ExtensionProfileSummary(id: e.key, name: e.value),
    ],
    activeProfileId: activeProfileId,
  );

  @override
  Future<ExtensionProfileApplyResult> applySelectedProfile(
    int profileId,
  ) async {
    applied.add(profileId);
    // 让出事件循环：真实切换是多段 I/O，handler 若没等它就会先跑。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (!existing.containsKey(profileId)) {
      return ExtensionProfileApplyResult(
        found: false,
        activeProfileId: activeProfileId,
      );
    }
    activeProfileId = profileId;
    _events.add('apply:$profileId');
    return ExtensionProfileApplyResult(found: true, activeProfileId: profileId);
  }
}

Future<List<List<TokenizedSegment>>> _noopTokenize(List<String> texts) async =>
    <List<TokenizedSegment>>[
      for (final String _ in texts) <TokenizedSegment>[],
    ];

Future<HttpClientResponse> _post(
  int port,
  String path,
  Map<String, dynamic> body, {
  int? profileId,
  String? rawProfileHeader,
}) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest req = await c.postUrl(
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  req.headers.contentType = ContentType.json;
  if (profileId != null) {
    req.headers.set('X-Fushi-Profile-Id', '$profileId');
  }
  if (rawProfileHeader != null) {
    req.headers.set('X-Fushi-Profile-Id', rawProfileHeader);
  }
  req.write(jsonEncode(body));
  return req.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async =>
    jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;

void main() {
  late FushiApiServer server;
  late _FakeProfileApi profiles;
  late int lookupActivity;

  Future<void> startServer({bool withProfileApi = true}) async {
    _events.clear();
    lookupActivity = 0;
    profiles = _FakeProfileApi(
      existing: <int, String>{1: '默认', 2: '英语'},
      activeProfileId: 1,
    );
    server = FushiApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      miningService: _FakeMining(),
      tokenizer: _noopTokenize,
      onLookupActivity: () => lookupActivity++,
      profileApi: withProfileApi ? profiles : null,
    );
    await server.start();
  }

  tearDown(() async => server.stop());

  test('/api/extension/profiles lists profiles and the active one', () async {
    await startServer();
    final HttpClientResponse resp = await _post(
      server.port,
      kExtensionProfilesPath,
      <String, dynamic>{},
    );
    expect(resp.statusCode, 200);
    expect(await _json(resp), <String, dynamic>{
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
      final HttpClientResponse resp = await _post(
        server.port,
        kExtensionProfilesPath,
        <String, dynamic>{},
      );
      expect(resp.statusCode, 404);
      await resp.drain<void>();
    },
  );

  test(
    'lookup with a selected profile applies it before the lookup runs',
    () async {
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'popupOnly': true},
        profileId: 2,
      );
      expect(resp.statusCode, 200);
      expect(resp.headers.value(kExtensionProfileActiveHeader), '2');
      expect(resp.headers.value(kExtensionProfileMissingHeader), isNull);
      await resp.drain<void>();
      expect(_events, <String>['apply:2', 'lookup:猫']);
      expect(lookupActivity, 0, reason: '显式选择压过「浏览器」媒体类型绑定，不能再触发绑定应用');
    },
  );

  test('mine and duplicate carry the selected profile too', () async {
    await startServer();
    final HttpClientResponse mine = await _post(
      server.port,
      '/api/mine',
      <String, dynamic>{
        'fields': <String, String>{'expression': '猫'},
        'sentence': '猫がいる',
      },
      profileId: 2,
    );
    expect(mine.statusCode, 200);
    expect(mine.headers.value(kExtensionProfileActiveHeader), '2');
    await mine.drain<void>();
    final HttpClientResponse dup = await _post(
      server.port,
      '/api/duplicate',
      <String, dynamic>{'expression': '猫', 'reading': 'ねこ'},
      profileId: 2,
    );
    expect(dup.statusCode, 200);
    await dup.drain<void>();
    // 每条按配置生效的请求都先过 applySelectedProfile（稳态快路径在 app 侧）。
    expect(_events, <String>['apply:2', 'mine', 'apply:2', 'duplicate']);
    expect(profiles.applied, <int>[2, 2]);
  });

  test(
    'deleted profile: request still served, missing header reported',
    () async {
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '犬', 'popupOnly': true},
        profileId: 9,
      );
      expect(resp.statusCode, 200);
      expect(resp.headers.value(kExtensionProfileMissingHeader), '9');
      expect(resp.headers.value(kExtensionProfileActiveHeader), '1');
      await resp.drain<void>();
      expect(_events, <String>['lookup:犬']);
    },
  );

  test(
    'no header keeps the old path (browser binding hook, no apply)',
    () async {
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '鳥', 'popupOnly': true},
      );
      expect(resp.statusCode, 200);
      expect(resp.headers.value(kExtensionProfileActiveHeader), isNull);
      await resp.drain<void>();
      expect(profiles.applied, isEmpty);
      expect(lookupActivity, 1);
    },
  );

  test('garbage header value is ignored like no header', () async {
    await startServer();
    for (final String raw in <String>['abc', '0', '-3']) {
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '魚', 'popupOnly': true},
        rawProfileHeader: raw,
      );
      expect(resp.statusCode, 200);
      await resp.drain<void>();
    }
    expect(profiles.applied, isEmpty);
  });

  test('profile-independent endpoints ignore the header', () async {
    await startServer();
    final HttpClientResponse resp = await _post(
      server.port,
      '/api/extension/status',
      <String, dynamic>{},
      profileId: 2,
    );
    expect(resp.statusCode, 200);
    expect(resp.headers.value(kExtensionProfileActiveHeader), isNull);
    await resp.drain<void>();
    expect(profiles.applied, isEmpty);
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
