import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-3425：iPad 串流 PC 游戏制卡——查词和写卡都在 PC，但弹窗在 iPad 本机渲染、
/// Glossary 也在本机导出。远端查词客户端必须按 `stylesRevision` 协议取回并缓存
/// **host** 的词典样式，并交给弹窗；老 host 不认该字段时照旧（回落样式端点）。
void main() {
  const FushiClientUrl pinned = FushiClientUrl(
    url: 'http://desk:8765',
    hostId: 'desk',
    token: 'desk-token',
  );

  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[pinned]);
  });
  tearDown(() async => db.close());

  http.Response json(Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  Map<String, dynamic> resultJson() => <String, dynamic>{
    'searchTerm': '猫',
    'bestLength': 1,
    'entries': <String>[
      DictionaryEntry(
        dictionaryName: '明鏡',
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
      ).toJson(),
    ],
  };

  /// 模拟新 host：按请求体的 `stylesRevision` 门控，与
  /// `buildRemoteDictionaryLookupResponse` 同一判据。
  ({MockClient client, List<Map<String, dynamic>> lookups, List<String> paths})
  newHost({required String Function() revision}) {
    final List<Map<String, dynamic>> lookups = <Map<String, dynamic>>[];
    final List<String> paths = <String>[];
    final MockClient client = MockClient((http.Request request) async {
      paths.add(request.url.path);
      if (request.url.path != '/api/lookup/dictionary') {
        return http.Response('unexpected', 500);
      }
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      lookups.add(body);
      final String current = revision();
      final bool stale =
          body.containsKey('stylesRevision') &&
          body['stylesRevision'] != current;
      return json(<String, dynamic>{
        'type': 'dictionaryResult',
        'result': resultJson(),
        'dictionaryStylesRevision': current,
        if (stale)
          'dictionaryStyles': <String, String>{
            '明鏡': '.gloss-$current{}',
            '大辞泉': '.sense{}',
          },
      });
    });
    return (client: client, lookups: lookups, paths: paths);
  }

  group('FushiRemoteLookupClient stylesRevision', () {
    test(
      'first lookup asks with an empty revision, later ones send the cached one',
      () async {
        final host = newHost(revision: () => 'r1');
        final FushiRemoteLookupClient client = FushiRemoteLookupClient(
          repo: repo,
          onlyCandidate: pinned,
          httpClient: host.client,
          trackDictionaryStyles: true,
        );

        await client.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 5,
        );
        final Map<String, String>? first = client.hostDictionaryStyles;
        expect(first, <String, String>{'明鏡': '.gloss-r1{}', '大辞泉': '.sense{}'});
        expect(client.dictionaryStylesRevision, 'r1');

        await client.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 5,
        );

        expect(
          host.lookups.map((Map<String, dynamic> b) => b['stylesRevision']),
          <String>['', 'r1'],
        );
        // 指纹没变：host 不重发正文，客户端沿用同一个实例（弹窗按身份去重）。
        expect(identical(client.hostDictionaryStyles, first), isTrue);
      },
    );

    test('a new host revision replaces the cached styles', () async {
      String revision = 'r1';
      final host = newHost(revision: () => revision);
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        onlyCandidate: pinned,
        httpClient: host.client,
        trackDictionaryStyles: true,
      );
      await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      );
      final Map<String, String>? first = client.hostDictionaryStyles;
      revision = 'r2';
      await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      );
      expect(identical(client.hostDictionaryStyles, first), isFalse);
      expect(client.hostDictionaryStyles!['明鏡'], '.gloss-r2{}');
      expect(client.dictionaryStylesRevision, 'r2');
    });

    test('untracked clients keep the old request body', () async {
      final host = newHost(revision: () => 'r1');
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        onlyCandidate: pinned,
        httpClient: host.client,
      );
      await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      );
      expect(host.lookups.single.containsKey('stylesRevision'), isFalse);
      expect(client.hostDictionaryStyles, isNull);
    });

    test(
      'an old host without the revision field leaves styles unset',
      () async {
        final FushiRemoteLookupClient client = FushiRemoteLookupClient(
          repo: repo,
          onlyCandidate: pinned,
          httpClient: MockClient(
            (http.Request request) async => json(<String, dynamic>{
              'type': 'dictionaryResult',
              'result': resultJson(),
            }),
          ),
          trackDictionaryStyles: true,
        );
        final DictionarySearchResult? result = await client.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 5,
        );
        expect(result, isNotNull);
        expect(client.hostDictionaryStyles, isNull);
      },
    );
  });

  // BUG-3612：iPad 看电脑媒体库视频制卡——查词走 `AppModel` 的 remote-first 路径
  // （不钉候选），弹窗在本机渲染、Glossary 在本机导出。结果必须自带 host 样式，
  // 弹窗按结果逐次判断用哪份（同一表面下一次可能是本机结果）。
  group('BUG-3612 remote results carry the host styles', () {
    test('tracked lookups attach the host styles to every result', () async {
      final host = newHost(revision: () => 'r1');
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: host.client,
        trackDictionaryStyles: true,
      );
      final DictionarySearchResult? first = await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      );
      expect(first!.remoteDictionaryStyles, <String, String>{
        '明鏡': '.gloss-r1{}',
        '大辞泉': '.sense{}',
      });

      final DictionarySearchResult? second = await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      );
      // 指纹没变：host 只回指纹，结果仍带同一个实例（弹窗按身份去重，不重注入）。
      expect(
        identical(second!.remoteDictionaryStyles, first.remoteDictionaryStyles),
        isTrue,
      );
      expect(
        host.lookups.map((Map<String, dynamic> b) => b['stylesRevision']),
        <String>['', 'r1'],
      );
      // kanji 附加等拷贝路径不丢样式。
      expect(
        identical(
          second
              .withKanjiResults(const <FushiKanjiResult>[])
              .remoteDictionaryStyles,
          first.remoteDictionaryStyles,
        ),
        isTrue,
      );
    });

    test('untracked lookups and old hosts leave results local', () async {
      final host = newHost(revision: () => 'r1');
      final DictionarySearchResult? untracked = await FushiRemoteLookupClient(
        repo: repo,
        httpClient: host.client,
      ).searchDictionary(term: '猫', wildcards: false, maximumTerms: 5);
      expect(untracked!.remoteDictionaryStyles, isNull);

      final DictionarySearchResult? oldHost = await FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient(
          (http.Request request) async => json(<String, dynamic>{
            'type': 'dictionaryResult',
            'result': resultJson(),
          }),
        ),
        trackDictionaryStyles: true,
      ).searchDictionary(term: '猫', wildcards: false, maximumTerms: 5);
      expect(oldHost!.remoteDictionaryStyles, isNull);
    });

    test('AppModel remote-first lookups reuse one style-tracking client', () {
      final String source = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      String block(String head) {
        final int start = source.indexOf(head);
        expect(start, isNonNegative, reason: head);
        return source.substring(start, source.indexOf('\n  }\n', start));
      }

      final String body = block(
        'Future<DictionarySearchResult?> _searchRemoteDictionary(',
      );
      // 每次查词新建客户端 = 指纹缓存随实例丢掉、结果不带样式（BUG-3612 的根因）。
      expect(body, isNot(contains('FushiRemoteLookupClient(')));
      // 允许 `_remoteDictionaryLookup` 与 `.searchDictionary(` 之间折行：#2472 合并后
      // 这次调用被折成两行，复用的仍是同一个缓存客户端。
      expect(
        body,
        matches(RegExp(r'_remoteDictionaryLookup\s*\.searchDictionary\(')),
      );
      expect(
        block('FushiRemoteLookupClient get _remoteDictionaryLookup'),
        contains('trackDictionaryStyles: true'),
      );
    });
  });

  group('InterconnectGameStreamDictionaryLookup', () {
    test(
      'popup resources carry the host styles and are not re-downloaded',
      () async {
        final host = newHost(revision: () => 'r1');
        final InterconnectGameStreamDictionaryLookup lookup =
            InterconnectGameStreamDictionaryLookup(
              repo: repo,
              peer: pinned,
              httpClient: host.client,
            );

        expect(lookup.popupResources.dictionaryStyles, isEmpty);
        await lookup.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 5,
        );
        final Map<String, String> first =
            lookup.popupResources.dictionaryStyles;
        expect(first['明鏡'], '.gloss-r1{}');

        await lookup.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 5,
        );
        expect(
          identical(lookup.popupResources.dictionaryStyles, first),
          isTrue,
        );
        // 全程只有查词请求，样式端点一次都没打。
        expect(host.paths, <String>[
          '/api/lookup/dictionary',
          '/api/lookup/dictionary',
        ]);
      },
    );

    test('an old host falls back to the styles endpoint', () async {
      final List<String> paths = <String>[];
      final InterconnectGameStreamDictionaryLookup lookup =
          InterconnectGameStreamDictionaryLookup(
            repo: repo,
            peer: pinned,
            httpClient: MockClient((http.Request request) async {
              paths.add(request.url.path);
              if (request.url.path == '/api/lookup/dictionary/styles') {
                return json(<String, dynamic>{
                  'type': 'dictionaryStyles',
                  'styles': <String, String>{'明鏡': '.legacy{}'},
                });
              }
              return json(<String, dynamic>{
                'type': 'dictionaryResult',
                'result': resultJson(),
              });
            }),
          );

      await lookup.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      );

      expect(lookup.popupResources.dictionaryStyles, <String, String>{
        '明鏡': '.legacy{}',
      });
      expect(paths, <String>[
        '/api/lookup/dictionary',
        '/api/lookup/dictionary/styles',
      ]);
    });
  });

  group('FushiSyncServer /api/lookup/dictionary', () {
    const String token = 'game-stream-styles';
    const Map<String, String> styles = <String, String>{
      '明鏡': '.gloss { color: red; }',
    };
    late FushiSyncServer server;

    setUp(() async {
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_gs_styles').path,
        port: 0,
        token: token,
        allowLan: false,
        remoteLookupService: _OneEntryLookup(),
        dictionaryStylesProvider: () => styles,
      );
      await server.start();
    });
    tearDown(() async => server.stop());

    Future<Map<String, dynamic>> lookup(Map<String, dynamic> extra) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/lookup/dictionary'),
        );
        request.headers.set(
          'authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(<String, dynamic>{'term': '猫', ...extra}));
        final HttpClientResponse response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await response.transform(utf8.decoder).join())
            as Map<String, dynamic>;
      } finally {
        client.close();
      }
    }

    test('ships styles once per revision and never to old clients', () async {
      final Map<String, dynamic> legacy = await lookup(<String, dynamic>{});
      expect(legacy.containsKey('dictionaryStyles'), isFalse);
      final String revision = legacy['dictionaryStylesRevision'] as String;

      final Map<String, dynamic> first = await lookup(<String, dynamic>{
        'stylesRevision': '',
      });
      expect(first['dictionaryStyles'], styles);
      expect(first['dictionaryStylesRevision'], revision);

      final Map<String, dynamic> cached = await lookup(<String, dynamic>{
        'stylesRevision': revision,
      });
      expect(cached.containsKey('dictionaryStyles'), isFalse);
      expect(cached['dictionaryStylesRevision'], revision);
      expect(cached['type'], 'dictionaryResult');
    });
  });
}

class _OneEntryLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => DictionarySearchResult(
    searchTerm: term,
    bestLength: term.length,
    entries: <DictionaryEntry>[
      DictionaryEntry(dictionaryName: '明鏡', word: term, meaning: 'm'),
    ],
  );

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}
