import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 卡组新卡按词频重排的 AnkiConnect 侧契约：
//   1. 卡组范围按 **卡组 id 子树** 圈（不用 `deck:"名"` 通配，BUG-2051），且限定
//      `is:new -deck:filtered`；
//   2. `cardsInfo` 分批、解析 `note/ord/due/type/fields`；
//   3. 写位置走 `multi` 里的 `setSpecificValueOfCard`，`keys=['due']` 且必带
//      `warning_check: true`（不带整条被 AnkiConnect 拒绝）；
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

Map<String, Object?> _card({
  required int id,
  required int note,
  int ord = 0,
  int due = 0,
  int type = 0,
  Map<String, String> fields = const <String, String>{'Expression': '猫'},
}) =>
    <String, Object?>{
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
      final List<AnkiCardInfo> infos =
          await s.cardsInfo(List<int>.generate(n, (int i) => i + 1));
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

    test('setCardsDueMany 打成 multi，每条带 warning_check 与 keys=[due]', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(
        rec,
        (Map<String, dynamic> body) {
          final List<dynamic> actions = (body['params']
              as Map<String, dynamic>)['actions'] as List<dynamic>;
          // 真 AnkiConnect 的形状：成功 [true]；异常 [[false, msg]]，error 仍为 null。
          return <Object?>[
            for (int i = 0; i < actions.length; i++)
              <String, Object?>{
                'result': i == 1
                    ? <Object?>[
                        <Object?>[false, 'card was not found: 2']
                      ]
                    : <Object?>[true],
                'error': null,
              },
          ];
        },
      );
      final List<AnkiConnectBatchResult> results = await s.setCardsDueMany(
        const <AnkiCardDueUpdate>[
          AnkiCardDueUpdate(cardId: 1, due: 1),
          AnkiCardDueUpdate(cardId: 2, due: 2),
          AnkiCardDueUpdate(cardId: 3, due: 3),
        ],
      );
      expect(rec.requests.length, 1, reason: '3 条打成一次 multi 往返');
      final Map<String, dynamic> body = rec.body(0);
      expect(body['action'], 'multi');
      final List<dynamic> actions =
          (body['params'] as Map<String, dynamic>)['actions'] as List<dynamic>;
      expect(actions.length, 3);
      final Map<String, dynamic> a0 = actions[0] as Map<String, dynamic>;
      expect(a0['action'], 'setSpecificValueOfCard');
      expect(a0['version'], 6);
      expect(a0['params'], <String, Object?>{
        'card': 1,
        'keys': <String>['due'],
        'newValues': <int>[1],
        'warning_check': true,
      });
      expect(
        results.map(ankiSetSpecificValueFailure).toList(),
        <String?>[null, 'card was not found: 2', null],
      );
    });

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
          final List<dynamic> actions = (body['params']
              as Map<String, dynamic>)['actions'] as List<dynamic>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'result': <Object?>[
                for (int i = 0; i < actions.length; i++)
                  <String, Object?>{
                    'result': <Object?>[true],
                    'error': null
                  },
              ],
              'error': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      await s.setCardsDueMany(const <AnkiCardDueUpdate>[
        AnkiCardDueUpdate(cardId: 1, due: 1),
        AnkiCardDueUpdate(cardId: 2, due: 2),
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

    test('ankiSetSpecificValueFailure 解读三种结果形状', () {
      expect(
        ankiSetSpecificValueFailure(
          const AnkiConnectBatchResult(result: <Object?>[true]),
        ),
        isNull,
      );
      expect(
        ankiSetSpecificValueFailure(
          const AnkiConnectBatchResult(result: false),
        ),
        isNotNull,
        reason: '参数形状不对时插件返回裸 false，不能当成功',
      );
      expect(
        ankiSetSpecificValueFailure(
          const AnkiConnectBatchResult(result: null, error: 'boom'),
        ),
        'boom',
      );
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
      expect((find['params'] as Map<String, dynamic>)['query'],
          '(did:1 OR did:2) is:new -deck:filtered');
    });

    test('listNewCards：卡组不存在时不发 findCards、返回空', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(
        rec,
        (Map<String, dynamic> body) =>
            body['action'] == 'deckNamesAndIds' ? <String, int>{'X': 1} : null,
      );
      final List<AnkiCardInfo> cards =
          await _Repo(service: s).listNewCards('Mining');
      expect(cards, isEmpty);
      expect(rec.requests.map((http.Request r) => jsonDecode(r.body)['action']),
          <String>['deckNamesAndIds']);
    });

    test('setNewCardPositions：逐条映射失败到 cardId', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(rec, (Map<String, dynamic> body) {
        final List<dynamic> actions = (body['params']
            as Map<String, dynamic>)['actions'] as List<dynamic>;
        return <Object?>[
          for (int i = 0; i < actions.length; i++)
            <String, Object?>{
              'result': i == 0
                  ? <Object?>[
                      <Object?>[false, 'boom']
                    ]
                  : <Object?>[true],
              'error': null,
            },
        ];
      });
      final AnkiCardDueWriteResult r =
          await _Repo(service: s).setNewCardPositions(
        const <AnkiCardDueUpdate>[
          AnkiCardDueUpdate(cardId: 7, due: 1),
          AnkiCardDueUpdate(cardId: 8, due: 2),
        ],
      );
      expect(r.written, 1);
      expect(r.failures, <int, String>{7: 'boom'});
    });

    test('空更新不发请求', () async {
      final _Recording rec = _Recording();
      final AnkiConnectService s = _service(rec, (_) => null);
      final AnkiCardDueWriteResult r = await _Repo(service: s)
          .setNewCardPositions(const <AnkiCardDueUpdate>[]);
      expect(r.written, 0);
      expect(rec.requests, isEmpty);
    });
  });

  group('其它后端', () {
    test('基类默认不支持重排', () {
      expect(_Plain().supportsDeckReposition, isFalse);
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
      final AnkiSettings s =
          AnkiSettings.fromJson(<String, dynamic>{'selectedDeckId': 1});
      expect(s.repositionSource, AnkiRepositionSource.dictionaries);
      expect(AnkiRepositionSource.fromName('garbage'),
          AnkiRepositionSource.dictionaries);
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
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}
