import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 卡组新卡按词频重排的 AnkiConnect 侧契约：
//   1. 卡组范围按 **卡组 id 子树** 圈（不用 `deck:"名"` 通配，BUG-2051），且限定
//      `is:new -deck:filtered`；
//   2. `cardsInfo` 分批、解析 `note/ord/due/type/fields`；
//   3. 写位置**只走**原生 `scheduling.repositionNewCards`（`/api/v1` JSON-RPC），
//      先用 `api.describe` 探测能力；探测不到就一张都不写、不发任何写 `due` 的
//      请求（AnkiConnect 26.10.11.0 起的 legacy.py 拒绝 `setSpecificValueOfCard`
//      写 `due`，原生方法只在 master a579cd5d76 之后才有）；
//   4. 仓储层对 `type != 0` 的卡二次过滤——复习卡的 due 是日期，绝不能当位置写。

class _Recording {
  final List<http.Request> requests = <http.Request>[];

  Map<String, dynamic> body(int i) =>
      jsonDecode(requests[i].body) as Map<String, dynamic>;
}

AnkiConnectService _service(
  _Recording rec,
  Object? Function(Map<String, dynamic> body) reply,
) {
  return AnkiConnectService(
    host: '127.0.0.1',
    port: 8765,
    client: MockClient((http.Request request) async {
      rec.requests.add(request);
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, Object?>{'result': reply(body), 'error': null}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );
}

/// 同时应答旧协议（`/`）与 API v1（`/api/v1`）的假 AnkiConnect。
///
/// [nativeReposition] = `api.describe` 里有没有可用的 `scheduling.repositionNewCards`；
/// null = 模拟没有 `/api/v1` 的旧版 AnkiConnect（对任何 body 都回旧协议的错误信封）。
/// [rpcError] 让某张卡的原生重排回错误（模拟它已不是新卡）。
class _DualFake {
  _DualFake({
    this.nativeReposition = true,
    this.rpcError = const <String, String>{},
    this.describeStatus = 200,
  });

  final bool? nativeReposition;
  final Map<String, String> rpcError;
  final int describeStatus;

  final List<http.Request> requests = <http.Request>[];

  /// 收到的每条 JSON-RPC 请求（批次拆开），按到达顺序。
  final List<Map<String, dynamic>> rpc = <Map<String, dynamic>>[];

  List<String> get rpcMethods => <String>[
    for (final Map<String, dynamic> r in rpc) r['method'] as String,
  ];

  /// 旧协议收到的 action 名（含 `multi` 子项）。
  List<String> get legacyActions => <String>[
    for (final http.Request r in requests)
      if (r.url.path != '/api/v1') ...<String>[
        jsonDecode(r.body)['action'] as String,
        if (jsonDecode(r.body)['action'] == 'multi')
          for (final dynamic a
              in (jsonDecode(r.body)['params']
                      as Map<String, dynamic>)['actions']
                  as List<dynamic>)
            (a as Map<String, dynamic>)['action'] as String,
      ],
  ];

  AnkiConnectService service({String apiKey = ''}) => AnkiConnectService(
    host: '127.0.0.1',
    port: 8765,
    apiKey: apiKey,
    client: MockClient((http.Request request) async {
      requests.add(request);
      final Object? decoded = jsonDecode(request.body);
      if (request.url.path == '/api/v1' && nativeReposition != null) {
        final Object? reply = decoded is List
            ? <Object?>[
                // 倒序回：上游不保证批内顺序，客户端必须按 id 对。
                for (final Object? item in decoded.reversed)
                  _rpcReply(item as Map<String, dynamic>),
              ]
            : _rpcReply(decoded as Map<String, dynamic>);
        return http.Response(
          jsonEncode(reply),
          decoded is! List ? describeStatus : 200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      final Map<String, dynamic> body = decoded as Map<String, dynamic>;
      if (!body.containsKey('action')) {
        // 旧版 AnkiConnect 不认路径、也不认 JSON-RPC：回旧协议错误信封。
        return http.Response(
          jsonEncode(<String, Object?>{
            'result': null,
            'error': 'unsupported action',
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, Object?>{'result': null, 'error': null}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );

  Map<String, Object?> _rpcReply(Map<String, dynamic> req) {
    rpc.add(req);
    final Object? id = req['id'];
    switch (req['method']) {
      case 'api.describe':
        return <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'apiMajor': 1,
            'ankiVersion': '26.09.3',
            'schema': <String, Object?>{},
            'methods': <Object?>[
              <String, Object?>{
                'name': 'notes.get',
                'available': true,
                'reason': null,
              },
              if (nativeReposition == true)
                <String, Object?>{
                  'name': 'scheduling.repositionNewCards',
                  'available': true,
                  'reason': null,
                },
            ],
            'limits': <String, Object?>{},
          },
        };
      case 'scheduling.repositionNewCards':
        final String cid =
            ((req['params'] as Map<String, dynamic>)['cardIds']
                        as List<dynamic>)
                    .single
                as String;
        final String? err = rpcError[cid];
        if (err != null) {
          return <String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, Object?>{
              'code': 1009,
              'message': err,
              'data': <String, Object?>{'type': 'invalidState'},
            },
          };
        }
        return <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{'changedCount': 1},
        };
    }
    return <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': -32601, 'message': 'Method not found'},
    };
  }
}

Map<String, Object?> _card({
  required int id,
  required int note,
  int ord = 0,
  int due = 0,
  int type = 0,
  Map<String, String> fields = const <String, String>{'Expression': '猫'},
}) => <String, Object?>{
  'cardId': id,
  'note': note,
  'ord': ord,
  'due': due,
  'type': type,
  'queue': type == 0 ? 0 : 2,
  'modelName': 'Lapis',
  'deckName': 'Mining',
  'fields': <String, Object?>{
    for (final MapEntry<String, String> e in fields.entries)
      e.key: <String, Object?>{'value': e.value, 'order': 0},
  },
};

void main() {
  group('ankiDeckNewCardsQuery', () {
    const Map<String, int> decks = <String, int>{
      'Mining': 1,
      'Mining::Anime': 2,
      'Mining::Anime::S1': 3,
      'Mining_old': 4,
      'Other': 5,
    };

    test('按 id 圈子树，名字相同前缀但不是子卡组的不算', () {
      expect(
        ankiDeckNewCardsQuery(decks, 'Mining'),
        '(did:1 OR did:2 OR did:3) is:new -deck:filtered',
        reason: 'Mining_old 与 Mining 只差一个字，deck:"Mining_" 通配会把它圈进来',
      );
    });

    test('叶子卡组只有自己一个 id', () {
      expect(
        ankiDeckNewCardsQuery(decks, 'Mining::Anime::S1'),
        'did:3 is:new -deck:filtered',
      );
    });

    test('找不到卡组 / 空名返回空串', () {
      expect(ankiDeckNewCardsQuery(decks, 'Nope'), '');
      expect(ankiDeckNewCardsQuery(decks, ''), '');
    });
  });

  group('AnkiConnectService 卡片级 action', () {
    test('findCards 原样送出查询串并解析 id 列表', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(rec, (_) => <Object>[11, 22.0]);
      final List<int> ids = await s.findCards('did:1 is:new');
      expect(ids, <int>[11, 22]);
      expect(rec.body(0)['action'], 'findCards');
      expect(rec.body(0)['params'], <String, Object?>{'query': 'did:1 is:new'});
    });

    test('cardsInfo 按 kCardsInfoBatchSize 分批并拍平字段', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(rec, (Map<String, dynamic> body) {
        final List<dynamic> cards =
            (body['params'] as Map<String, dynamic>)['cards'] as List<dynamic>;
        return <Object?>[
          for (final dynamic id in cards)
            _card(id: id as int, note: id * 10, due: id, ord: 1),
          <String, Object?>{}, // 不存在的卡：空对象，必须被跳过
        ];
      });
      final int n = AnkiConnectService.kCardsInfoBatchSize * 2 + 1;
      final List<AnkiCardInfo> infos = await s.cardsInfo(
        List<int>.generate(n, (int i) => i + 1),
      );
      expect(rec.requests.length, 3, reason: '2 满批 + 1 尾批');
      expect(infos.length, n);
      final AnkiCardInfo first = infos.first;
      expect(first.cardId, 1);
      expect(first.noteId, 10);
      expect(first.ord, 1);
      expect(first.due, 1);
      expect(first.isNew, isTrue);
      expect(first.fields, <String, String>{'Expression': '猫'});
    });

    test(
      '能力探测：POST /api/v1 api.describe，方法可用 → true；apiKey 走 Bearer',
      () async {
        final _DualFake fake = _DualFake();
        expect(
          await fake
              .service(apiKey: 'secret')
              .supportsNativeRepositionNewCards(),
          isTrue,
        );
        final http.Request req = fake.requests.single;
        expect(req.url.path, '/api/v1');
        expect(req.headers['Authorization'], 'Bearer secret');
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['jsonrpc'], '2.0');
        expect(body['method'], 'api.describe');
      },
    );

    test('能力探测：方法不在清单 / 旧版没有 /api/v1 → false', () async {
      expect(
        await _DualFake(
          nativeReposition: false,
        ).service().supportsNativeRepositionNewCards(),
        isFalse,
        reason: '26.10.11.0 ~ 26.10.14.0 发布版：有 /api/v1 但没有原生重排',
      );
      expect(
        await _DualFake(
          nativeReposition: null,
        ).service().supportsNativeRepositionNewCards(),
        isFalse,
        reason: '旧版 AnkiConnect 对 /api/v1 回旧协议错误信封',
      );
    });

    test('能力探测：401 鉴权失败下不了结论，抛而不是当成不支持', () async {
      await expectLater(
        _DualFake(
          describeStatus: 401,
        ).service().supportsNativeRepositionNewCards(),
        throwsA(isA<AnkiConnectException>()),
      );
    });

    test(
      'repositionNewCards：每卡一条 JSON-RPC，按 kRpcBatchSize 分批、按 id 对回结果',
      () async {
        final _DualFake fake = _DualFake(
          rpcError: <String, String>{'102': 'Card is not new.'},
        );
        final int n = AnkiConnectService.kRpcBatchSize + 1;
        final List<AnkiConnectBatchResult> results = await fake
            .service()
            .repositionNewCards(<AnkiCardDueUpdate>[
              for (int i = 0; i < n; i++)
                AnkiCardDueUpdate(cardId: 100 + i, due: i + 1),
            ]);
        expect(fake.requests.length, 2, reason: '1 满批 + 1 尾批');
        expect(
          fake.requests.every((http.Request r) => r.url.path == '/api/v1'),
          isTrue,
        );
        expect(fake.legacyActions, isEmpty, reason: '不走旧协议，更不发写 due 的请求');
        final Map<String, dynamic> first = fake.rpc.firstWhere(
          (Map<String, dynamic> r) =>
              ((r['params'] as Map<String, dynamic>)['cardIds']
                      as List<dynamic>)
                  .single ==
              '100',
        );
        expect(first['method'], 'scheduling.repositionNewCards');
        expect(first['params'], <String, Object?>{
          'cardIds': <String>['100'],
          'startingFrom': 1,
          'stepSize': 1,
          'randomize': false,
          'shiftExisting': false,
        });
        expect(results.length, n);
        expect(results[0].error, isNull);
        expect(results[0].result, 1);
        expect(results[2].error, 'invalidState: Card is not new.');
        expect(results[n - 1].error, isNull);
      },
    );

    test('配置了 apiKey 时 multi 的每条子 action 都带 key（真机实测：不带整批被拒）', () async {
      final List<http.Request> issued = <http.Request>[];
      final AnkiConnectService s = AnkiConnectService(
        host: '127.0.0.1',
        port: 8765,
        apiKey: 'secret',
        client: MockClient((http.Request request) async {
          issued.add(request);
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          final List<dynamic> actions =
              (body['params'] as Map<String, dynamic>)['actions']
                  as List<dynamic>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'result': <Object?>[
                for (int i = 0; i < actions.length; i++)
                  <String, Object?>{'result': 6, 'error': null},
              ],
              'error': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      await s.requestMulti(const <AnkiConnectAction>[
        AnkiConnectAction('version'),
        AnkiConnectAction('deckNames'),
      ]);
      final Map<String, dynamic> body =
          jsonDecode(issued.single.body) as Map<String, dynamic>;
      expect(body['key'], 'secret');
      final List<dynamic> actions =
          (body['params'] as Map<String, dynamic>)['actions'] as List<dynamic>;
      for (final dynamic a in actions) {
        expect((a as Map<String, dynamic>)['key'], 'secret');
      }
    });
  });

  group('AnkiConnectRepository 重排', () {
    test('listNewCards：按子树 id 查询，type != 0 的卡被丢弃', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(rec, (Map<String, dynamic> body) {
        switch (body['action']) {
          case 'deckNamesAndIds':
            return <String, int>{'Mining': 1, 'Mining::Sub': 2};
          case 'findCards':
            return <int>[1, 2, 3];
          case 'cardsInfo':
            return <Object?>[
              _card(id: 1, note: 10, due: 5),
              // 查询到写回之间刚被学过的卡：type 变 2，due 已是日期。
              _card(id: 2, note: 20, due: 19000, type: 2),
              _card(id: 3, note: 30, due: 7),
            ];
        }
        return null;
      });
      final _Repo repo = _Repo(service: s);
      expect(repo.supportsDeckReposition, isTrue);
      final List<AnkiCardInfo> cards = await repo.listNewCards('Mining');
      expect(cards.map((AnkiCardInfo c) => c.cardId).toList(), <int>[1, 3]);
      final Map<String, dynamic> find = rec.body(1);
      expect(find['action'], 'findCards');
      expect(
        (find['params'] as Map<String, dynamic>)['query'],
        '(did:1 OR did:2) is:new -deck:filtered',
      );
    });

    test('listNewCards：卡组不存在时不发 findCards、返回空', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(
        rec,
        (Map<String, dynamic> body) =>
            body['action'] == 'deckNamesAndIds' ? <String, int>{'X': 1} : null,
      );
      final List<AnkiCardInfo> cards = await _Repo(
        service: s,
      ).listNewCards('Mining');
      expect(cards, isEmpty);
      expect(
        rec.requests.map((http.Request r) => jsonDecode(r.body)['action']),
        <String>['deckNamesAndIds'],
      );
    });

    test('probeDeckReposition：跟着 api.describe 走', () async {
      expect(
        await _Repo(service: _DualFake().service()).probeDeckReposition(),
        isTrue,
      );
      expect(
        await _Repo(
          service: _DualFake(nativeReposition: false).service(),
        ).probeDeckReposition(),
        isFalse,
      );
    });

    test(
      'setNewCardPositions：有原生接口 → 走 scheduling.repositionNewCards，逐条映射失败',
      () async {
        final _DualFake fake = _DualFake(
          rpcError: <String, String>{'7': 'Card is not new.'},
        );
        final AnkiCardDueWriteResult r = await _Repo(service: fake.service())
            .setNewCardPositions(const <AnkiCardDueUpdate>[
              AnkiCardDueUpdate(cardId: 7, due: 1),
              AnkiCardDueUpdate(cardId: 8, due: 2),
            ]);
        expect(r.written, 1);
        expect(r.failures, <int, String>{7: 'invalidState: Card is not new.'});
        expect(fake.rpcMethods, <String>[
          'api.describe',
          'scheduling.repositionNewCards',
          'scheduling.repositionNewCards',
        ]);
        expect(fake.legacyActions, isEmpty);
      },
    );

    test('setNewCardPositions：探测不到原生接口 → 抛 Unsupported，一条写请求都不发', () async {
      for (final bool? native in <bool?>[false, null]) {
        final _DualFake fake = _DualFake(nativeReposition: native);
        await expectLater(
          _Repo(service: fake.service()).setNewCardPositions(
            const <AnkiCardDueUpdate>[AnkiCardDueUpdate(cardId: 7, due: 1)],
          ),
          throwsA(isA<AnkiRepositionUnsupportedException>()),
        );
        expect(
          fake.rpcMethods.where((String m) => m != 'api.describe'),
          isEmpty,
          reason: 'native=$native',
        );
        expect(
          fake.legacyActions,
          isNot(contains('setSpecificValueOfCard')),
          reason: '新版 AnkiConnect 禁止写 due：绝不退回逐卡写 due',
        );
        expect(fake.legacyActions, isEmpty);
      }
    });

    test('空更新不发请求', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(rec, (_) => null);
      final AnkiCardDueWriteResult r = await _Repo(
        service: s,
      ).setNewCardPositions(const <AnkiCardDueUpdate>[]);
      expect(r.written, 0);
      expect(rec.requests, isEmpty);
    });
  });

  group('其它后端', () {
    test('基类默认不支持重排', () async {
      expect(_Plain().supportsDeckReposition, isFalse);
      expect(await _Plain().probeDeckReposition(), isFalse);
      expect(() => _Plain().listNewCards('x'), throwsUnsupportedError);
    });
  });

  group('AnkiSettings 重排偏好', () {
    test('缺省值与 JSON 往返', () {
      const AnkiSettings d = AnkiSettings();
      expect(d.repositionSource, AnkiRepositionSource.dictionaries);
      expect(d.repositionDictionaries, isEmpty);
      expect(d.repositionAggregate, 'harmonic');

      final AnkiSettings s = d.copyWith(
        repositionSource: AnkiRepositionSource.field,
        repositionDictionaries: <String>['JPDB', 'BCCWJ'],
        repositionAggregate: 'min',
      );
      final AnkiSettings back = AnkiSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.repositionSource, AnkiRepositionSource.field);
      expect(back.repositionDictionaries, <String>['JPDB', 'BCCWJ']);
      expect(back.repositionAggregate, 'min');
    });

    test('老存档没有这些键时回落缺省，不炸', () {
      final AnkiSettings s = AnkiSettings.fromJson(<String, dynamic>{
        'selectedDeckId': 1,
      });
      expect(s.repositionSource, AnkiRepositionSource.dictionaries);
      expect(
        AnkiRepositionSource.fromName('garbage'),
        AnkiRepositionSource.dictionaries,
      );
    });
  });
}

class _Repo extends AnkiConnectRepository {
  _Repo({required AnkiConnectService service}) : super(service: service);

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();
}

class _Plain extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}
