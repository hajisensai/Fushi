// 复习模块的 app 侧接线：
// - 查词弹窗词状态桥（srsTermStatus / srsOpenCard）：模块关着恒 null / false，开着回正确形状；
// - Fushi API 的 /api/srs/term-status、/api/srs/open：模块关着 404；
// - SrsAppRuntime：开着时装上 AnkiConnect 兼容端点（根路径可用）、自环 id、同步后置步骤、
//   SrsAppHost；dispose（模块关）后全部卸下，根路径 404；
// - srsAppRuntimeProvider：模块关着为 null，什么也不装。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_term_status_bridge.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show fushiAnkiConnectCompatInstanceId;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

class _NoLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

class _RuntimeAppModel extends AppModel {
  _RuntimeAppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;

  @override
  String get fushiApiKey => '';
}

Future<(int, String)> _post(int port, String path, String body) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.post('127.0.0.1', port, path);
    req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
    req.add(utf8.encode(body));
    final HttpClientResponse res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

void main() {
  // 运行时装 AppLifecycleListener 需要 binding；但 binding 会把 HttpClient 换成恒回
  // 400 的假实现，本文件要打真的本机 server，所以换回真实实现。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late FushiDatabase db;
  late SrsDbStore store;
  late String noteId;
  final List<String> opened = <String>[];

  SrsAppHost host() => SrsAppHost(
    readStore: () async => store,
    openNote: (String id) async {
      opened.add(id);
      return true;
    },
    openBrowse: () async => true,
  );

  setUp(() async {
    opened.clear();
    (db, store) = await openSrsTestStore();
    noteId = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '雪',
        srsLapisFieldId(kSrsTestProfile, 'ExpressionReading'): 'ゆき',
      },
    );
  });

  tearDown(() async {
    SrsAppHost.current = null;
    await db.close();
  });

  group('弹窗词状态桥', () {
    test('模块关着（host = null）：恒 null / false', () async {
      expect(
        await srsHandleTermStatusBridge(<dynamic>[
          <String, String>{'expression': '雪', 'reading': 'ゆき'},
        ], null),
        isNull,
      );
      expect(
        await srsHandleOpenCardBridge(<dynamic>[
          <String, String>{'cardId': 'x'},
        ], null),
        isFalse,
      );
    });

    test(
      '开着：有这个词回 {queue,dueLabel,suspended,cardId,noteId,cardCount,tooltip}',
      () async {
        final Map<String, Object?>? s = await srsHandleTermStatusBridge(
          <dynamic>[
            <String, String>{'expression': '雪', 'reading': 'ゆき'},
          ],
          host(),
        );
        expect(s, isNotNull);
        expect(s!.keys.toSet(), <String>{
          'queue',
          'dueLabel',
          'suspended',
          'cardId',
          'noteId',
          'cardCount',
          'tooltip',
        });
        expect(s['queue'], 'new');
        expect(s['dueLabel'], t.srs_status_new);
        expect(s['suspended'], isFalse);
        expect(s['noteId'], noteId);
        expect(s['cardCount'], 1);
        // 同形异读 / 没有的词 → null。
        expect(
          await srsHandleTermStatusBridge(<dynamic>[
            <String, String>{'expression': '雪', 'reading': 'せつ'},
          ], host()),
          isNull,
        );
        expect(
          await srsHandleTermStatusBridge(<dynamic>[
            <String, String>{'expression': '雨', 'reading': ''},
          ], host()),
          isNull,
        );
        // 暂停后标签变「已暂停」。
        await store.setSuspended(s['cardId']! as String, true);
        final Map<String, Object?>? suspended = await srsHandleTermStatusBridge(
          <dynamic>[
            <String, String>{'expression': '雪', 'reading': 'ゆき'},
          ],
          host(),
        );
        expect(suspended!['suspended'], isTrue);
        expect(suspended['dueLabel'], t.srs_status_suspended);
      },
    );

    test('批量桥：模块关着 / 参数不对 / 超过上限回 null', () async {
      final List<dynamic> ok = <dynamic>[
        <String, Object?>{
          'terms': <Map<String, String>>[
            <String, String>{'expression': '雪', 'reading': 'ゆき'},
          ],
        },
      ];
      expect(await srsHandleTermStatusBatchBridge(ok, null), isNull);
      expect(
        await srsHandleTermStatusBatchBridge(<dynamic>[
          <String, Object?>{'terms': 'x'},
        ], host()),
        isNull,
      );
      expect(
        await srsHandleTermStatusBatchBridge(<dynamic>[
          <String, Object?>{
            'terms': <Map<String, String>>[
              for (int i = 0; i <= kSrsTermStatusBatchMax; i++)
                <String, String>{'expression': '語$i'},
            ],
          },
        ], host()),
        isNull,
      );
    });

    test('批量桥：一个可见批次只查一次存储，回包与单条逐个一致、等长同序', () async {
      // 同形异读：「上手」两张卡分别是 じょうず / うわて。
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '上手',
          srsLapisFieldId(kSrsTestProfile, 'ExpressionReading'): 'じょうず',
        },
      );
      final String uwate = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '上手',
          srsLapisFieldId(kSrsTestProfile, 'ExpressionReading'): 'うわて',
        },
      );
      final List<SrsTermQuery> terms = <SrsTermQuery>[
        const SrsTermQuery('雪', 'ゆき'),
        const SrsTermQuery('雨'),
        const SrsTermQuery('上手', 'じょうず'),
        const SrsTermQuery('上手', 'うわて'),
        const SrsTermQuery('雪', 'ゆき'),
      ];
      final List<int> batchSizes = <int>[];
      final List<Map<String, Object?>?> got = await srsLookupTermStatusPayloads(
        store,
        terms,
        lookup: (List<SrsTermQuery> qs) {
          batchSizes.add(qs.length);
          return store.lookupTermStatus(qs);
        },
      );
      // 同形异读必须分层（存储层按词形回结果），其余一层：雪/雨/上手(じょうず) + 上手(うわて)。
      expect(batchSizes, <int>[3, 1]);
      expect(got, hasLength(terms.length));
      for (int i = 0; i < terms.length; i++) {
        expect(
          got[i],
          await srsLookupTermStatusPayload(
            store,
            expression: terms[i].expression,
            reading: terms[i].reading ?? '',
          ),
          reason: 'term $i',
        );
      }
      expect(got[1], isNull);
      expect(got[3]!['noteId'], uwate);
      expect(got[2]!['noteId'], isNot(uwate));

      // 宿主装配：一次桥调用 = 一次 readStore + 一层查询。
      int reads = 0;
      final SrsAppHost counting = SrsAppHost(
        readStore: () async {
          reads++;
          return store;
        },
        openNote: (String id) async => true,
        openBrowse: () async => true,
      );
      final Map<String, Object?>? reply = await srsHandleTermStatusBatchBridge(
        <dynamic>[
          <String, Object?>{
            'terms': <Map<String, String>>[
              <String, String>{'expression': '雪', 'reading': 'ゆき'},
              <String, String>{'expression': '雨', 'reading': ''},
            ],
          },
        ],
        counting,
      );
      expect(reads, 1);
      final List<Object?> statuses = reply!['statuses']! as List<Object?>;
      expect(statuses, hasLength(2));
      expect((statuses[0]! as Map<String, Object?>)['noteId'], noteId);
      expect(statuses[1], isNull);
    });

    test('端到端耗时：一屏 20 个词逐条 vs 一次批量（打印供 PR 记录）', () async {
      final List<SrsTermQuery> terms = <SrsTermQuery>[
        for (int i = 0; i < 20; i++) SrsTermQuery('語$i', 'ご$i'),
      ];
      for (int i = 0; i < 20; i += 2) {
        await store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kSrsTestProfile, 'Expression'): '語$i',
            srsLapisFieldId(kSrsTestProfile, 'ExpressionReading'): 'ご$i',
          },
        );
      }
      final SrsAppHost h = host();
      // 预热（首次查询的语句准备 / 牌组树缓存）。
      await h.termStatuses(terms);
      final Stopwatch singles = Stopwatch()..start();
      final List<Map<String, Object?>?> one = <Map<String, Object?>?>[
        for (final SrsTermQuery q in terms)
          await h.termStatus(q.expression, q.reading ?? ''),
      ];
      singles.stop();
      final Stopwatch batch = Stopwatch()..start();
      final List<Map<String, Object?>?> many = await h.termStatuses(terms);
      batch.stop();
      expect(many, one);
      expect(many.whereType<Map<String, Object?>>(), hasLength(10));
      // ignore: avoid_print
      print(
        'srs term status, 20 visible terms: '
        '20 single round trips ${singles.elapsedMicroseconds} us vs '
        '1 batch ${batch.elapsedMicroseconds} us (host side, in-memory store)',
      );
    });

    test('打开卡片：只给 cardId 时反查 noteId', () async {
      final String cardId = (await store.cardsOfNote(noteId)).single.id;
      expect(
        await srsHandleOpenCardBridge(<dynamic>[
          <String, String>{'cardId': cardId},
        ], host()),
        isTrue,
      );
      expect(opened, <String>[noteId]);
    });

    test('复习卡的到期标签', () {
      SrsTermStatus st(int? dueDay) => SrsTermStatus(
        cardId: 'c',
        noteId: 'n',
        queue: SrsQueue.review,
        suspended: false,
        deckId: 'd',
        cardCount: 1,
        dueDay: dueDay,
      );
      expect(srsTermStatusLabel(st(10), today: 10), t.srs_status_due);
      expect(
        srsTermStatusLabel(st(13), today: 10),
        t.srs_status_review_in(n: 3),
      );
    });
  });

  group('Fushi API /api/srs/*', () {
    late FushiApiServer server;
    SrsExtensionApi? api;

    setUp(() async {
      api = null;
      server = FushiApiServer(
        port: 0,
        lookupService: _NoLookup(),
        tokenizer: (List<String> ts) async => <List<TokenizedSegment>>[
          for (final String t in ts) <TokenizedSegment>[(text: t, reading: '')],
        ],
        srsApiProvider: () => api,
      );
      await server.start();
    });

    tearDown(() => server.stop());

    test('模块关着：两个端点都 404', () async {
      expect(
        (await _post(
          server.port,
          '/api/srs/term-status',
          '{"expression":"雪"}',
        )).$1,
        404,
      );
      expect(
        (await _post(server.port, '/api/srs/open', '{"cardId":"x"}')).$1,
        404,
      );
    });

    test('开着：回 {status: …}；没有的词 status 为 null；open 回 opened', () async {
      api = host();
      final (int code, String body) = await _post(
        server.port,
        '/api/srs/term-status',
        '{"expression":"雪","reading":"ゆき"}',
      );
      expect(code, 200);
      final Map<String, dynamic> status =
          (jsonDecode(body) as Map<String, dynamic>)['status']
              as Map<String, dynamic>;
      expect(status['noteId'], noteId);
      expect(status['queue'], 'new');
      final (int c2, String b2) = await _post(
        server.port,
        '/api/srs/term-status',
        '{"expression":"雨"}',
      );
      expect(c2, 200);
      expect((jsonDecode(b2) as Map<String, dynamic>)['status'], isNull);
      final (int c3, String b3) = await _post(
        server.port,
        '/api/srs/open',
        jsonEncode(<String, String>{
          'cardId': status['cardId'] as String,
          'noteId': noteId,
        }),
      );
      expect(c3, 200);
      expect(jsonDecode(b3), <String, dynamic>{'opened': true});
    });

    test('批量端点：模块关着 404；一次请求回等长同序；超上限 400', () async {
      const String body =
          '{"terms":[{"expression":"雪","reading":"ゆき"},{"expression":"雨"}]}';
      expect(
        (await _post(server.port, '/api/srs/term-status-batch', body)).$1,
        404,
      );
      api = host();
      final (int code, String text) = await _post(
        server.port,
        '/api/srs/term-status-batch',
        body,
      );
      expect(code, 200);
      final List<dynamic> statuses =
          (jsonDecode(text) as Map<String, dynamic>)['statuses']
              as List<dynamic>;
      expect(statuses, hasLength(2));
      expect((statuses[0] as Map<String, dynamic>)['noteId'], noteId);
      expect(statuses[1], isNull);

      // 扩展链路端到端（真本机 HTTP）：一屏 20 个词逐条 vs 一次批量（打印供 PR 记录）。
      final List<Map<String, String>> screen = <Map<String, String>>[
        for (int i = 0; i < 20; i++)
          <String, String>{'expression': '語$i', 'reading': 'ご$i'},
      ];
      final Stopwatch singles = Stopwatch()..start();
      for (final Map<String, String> term in screen) {
        expect(
          (await _post(
            server.port,
            '/api/srs/term-status',
            jsonEncode(term),
          )).$1,
          200,
        );
      }
      singles.stop();
      final Stopwatch batch = Stopwatch()..start();
      expect(
        (await _post(
          server.port,
          '/api/srs/term-status-batch',
          jsonEncode(<String, Object?>{'terms': screen}),
        )).$1,
        200,
      );
      batch.stop();
      // ignore: avoid_print
      print(
        'srs term status over HTTP, 20 visible terms: '
        '20 requests ${singles.elapsedMicroseconds} us vs '
        '1 batch request ${batch.elapsedMicroseconds} us',
      );
      expect(
        (await _post(
          server.port,
          '/api/srs/term-status-batch',
          jsonEncode(<String, Object?>{
            'terms': <Map<String, String>>[
              for (int i = 0; i <= kSrsTermStatusBatchMax; i++)
                <String, String>{'expression': '語$i'},
            ],
          }),
        )).$1,
        400,
      );
      expect(
        (await _post(
          server.port,
          '/api/srs/term-status-batch',
          '{"terms":1}',
        )).$1,
        400,
      );
    });
  });

  group('SrsAppRuntime', () {
    test('装上：AnkiConnect 根路径可用、自环 id、同步后置步骤、SrsAppHost；卸下后全部清空', () async {
      final _RuntimeAppModel app = _RuntimeAppModel(db);
      final SrsAppRuntime runtime = SrsAppRuntime(
        app: app,
        readStore: () async => store,
        readMedia: () async => null,
        engine: () => const SrsTestEngine(),
        bumpRevision: () {},
        bumpPulledRevision: () {},
      );
      expect(app.srsAnkiConnectEndpoint, isNull);
      runtime.install();
      addTearDown(runtime.dispose);
      expect(app.srsAnkiConnectEndpoint, isNotNull);
      expect(fushiAnkiConnectCompatInstanceId, runtime.instanceId);
      expect(syncChannelPostRunHook, isNotNull);
      expect(SrsAppHost.current, isNotNull);

      final FushiApiServer server = FushiApiServer(
        port: 0,
        lookupService: _NoLookup(),
        tokenizer: (List<String> ts) async => <List<TokenizedSegment>>[
          for (final String t in ts) <TokenizedSegment>[(text: t, reading: '')],
        ],
        ankiConnectEndpoint: app.srsAnkiConnectEndpoint,
      );
      await server.start();
      addTearDown(server.stop);
      final (int code, String body) = await _post(
        server.port,
        '/',
        '{"action":"deckNames","version":6}',
      );
      expect(code, 200);
      expect((jsonDecode(body) as Map)['result'], <String>['Default']);
      final (int idCode, String idBody) = await _post(
        server.port,
        '/',
        '{"action":"fushiIdentify","version":6}',
      );
      expect(idCode, 200);
      expect(idBody, contains(runtime.instanceId));

      runtime.dispose();
      expect(app.srsAnkiConnectEndpoint, isNull);
      expect(fushiAnkiConnectCompatInstanceId, isNull);
      expect(syncChannelPostRunHook, isNull);
      expect(SrsAppHost.current, isNull);
      server.ankiConnectEndpoint = app.srsAnkiConnectEndpoint;
      final (int after, _) = await _post(
        server.port,
        '/',
        '{"action":"version","version":6}',
      );
      expect(after, 404);
    });

    test('srsAppRuntimeProvider：模块关着为 null，什么也不装', () {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => _RuntimeAppModel(db)),
          srsModuleEnabledProvider.overrideWithValue(false),
        ],
      );
      addTearDown(c.dispose);
      installSrsAppRuntime(c);
      expect(c.read(srsAppRuntimeProvider), isNull);
      expect(SrsAppHost.current, isNull);
      expect(syncChannelPostRunHook, isNull);
      expect(fushiAnkiConnectCompatInstanceId, isNull);
    });

    test('srsAppRuntimeProvider：开着时装上，容器销毁时卸下', () {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => _RuntimeAppModel(db)),
          srsModuleEnabledProvider.overrideWithValue(true),
          srsStoreProvider.overrideWith((Ref ref) async => store),
          srsEngineProvider.overrideWithValue(const SrsTestEngine()),
        ],
      );
      installSrsAppRuntime(c);
      expect(c.read(srsAppRuntimeProvider), isNotNull);
      expect(SrsAppHost.current, isNotNull);
      expect(syncChannelPostRunHook, isNotNull);
      c.dispose();
      expect(SrsAppHost.current, isNull);
      expect(syncChannelPostRunHook, isNull);
      expect(fushiAnkiConnectCompatInstanceId, isNull);
    });
  });
}
