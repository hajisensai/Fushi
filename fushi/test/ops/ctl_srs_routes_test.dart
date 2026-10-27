// 控制通道 `srs` 域（spec docs/specs/2026-10-26-ai-operations-agent-design.md §8 P2）：
// 牌组 / 笔记搜索 / 一条笔记 / 统计只读；冲突中心（被扣住的删除、被覆盖的标志、重复笔记）
// 调冲突中心页同一组 store 方法。真 SrsDbStore（内存主库 + 临时 srs.db），同步 v2 的两台设备
// 经内存位置同步。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;

import '../srs/srs_test_support.dart';

/// 按 `METHOD path` 找路由并调用。
Future<Object?> _call(
  List<CtlRoute> routes,
  String method,
  String path, {
  Map<String, Object?> body = const <String, Object?>{},
}) {
  for (final CtlRoute route in routes) {
    if (route.method != method) continue;
    final Map<String, String>? params = route.match(path);
    if (params == null) continue;
    return route.handler(
      CtlCall(method: method, path: path, params: params, body: body),
    );
  }
  throw StateError('没有路由 $method $path');
}

Matcher _failure(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

Future<String> _addNote(SrsDbStore s, String expression, String reading) =>
    s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
        srsLapisReadingFieldId(kSrsTestProfile): reading,
      },
    );

/// 两台设备经内存位置同步（同 srs_conflicts_held_delete_test）。
class _TwoDevices {
  _TwoDevices(this.dbs, this.a, this.b);

  final List<FushiDatabase> dbs;
  final SrsDbStore a;
  final SrsDbStore b;
  final SrsMemoryLocationStore location = SrsMemoryLocationStore();

  static Future<_TwoDevices> open() async {
    final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
      deviceId: 'a',
    );
    final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
      deviceId: 'b',
    );
    return _TwoDevices(<FushiDatabase>[dbA, dbB], a, b);
  }

  Future<void> syncAll() async {
    for (int r = 0; r < 2; r++) {
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        await srsSync2Round(
          host: s,
          location: location,
          locationId: 'test',
          nowMs: () => s.now().$1,
        );
      }
    }
  }

  Future<void> close() async {
    for (final FushiDatabase db in dbs) {
      await db.close();
    }
  }
}

List<CtlRoute> _routesFor(
  SrsDbStore? store, {
  bool Function()? enabled,
  void Function()? changed,
}) => buildSrsCtlRoutesFor(
  SrsCtlDeps(
    store: () async => store,
    moduleEnabled: enabled ?? () => true,
    changed: changed ?? () {},
  ),
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('门控', () {
    test('模块关 / 复习库没就绪 → 422', () async {
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(db.close);
      await expectLater(
        _call(
          _routesFor(store, enabled: () => false),
          'GET',
          '$kSrsCtlRoot/decks',
        ),
        _failure(422),
      );
      await expectLater(
        _call(_routesFor(null), 'GET', '$kSrsCtlRoot/stats'),
        _failure(422),
      );
    });
  });

  group('查询', () {
    late FushiDatabase db;
    late SrsDbStore store;
    late List<CtlRoute> routes;
    late String fish;

    setUp(() async {
      (db, store) = await openSrsTestStore();
      routes = _routesFor(store);
      fish = await _addNote(store, '魚', 'さかな');
      await _addNote(store, '犬', 'いぬ');
    });
    tearDown(() => db.close());

    test('decks 列出牌组与计数', () async {
      final Map<String, Object?> r =
          (await _call(routes, 'GET', '$kSrsCtlRoot/decks'))!
              as Map<String, Object?>;
      final List<Object?> decks = r['decks']! as List<Object?>;
      expect(decks, isNotEmpty);
      final int newCards = <int>[
        for (final Object? d in decks)
          if ((d! as Map<String, Object?>)['depth'] == 0)
            (d as Map<String, Object?>)['new']! as int,
      ].fold<int>(0, (int a, int b) => a + b);
      expect(newCards, greaterThanOrEqualTo(2));
    });

    test('notes：Anki 查询 / 按字段包含 / mode 校验；note 看一条', () async {
      Future<List<Object?>> items(Map<String, Object?> body) async =>
          ((await _call(routes, 'GET', '$kSrsCtlRoot/notes', body: body))!
                  as Map<String, Object?>)['items']!
              as List<Object?>;

      expect(await items(const <String, Object?>{}), hasLength(2));
      final List<Object?> hit = await items(<String, Object?>{'q': '魚'});
      expect(hit, hasLength(1));
      expect((hit.single! as Map<String, Object?>)['noteId'], fish);
      expect(
        await items(<String, Object?>{'field': 'Expression', 'q': '犬'}),
        hasLength(1),
      );
      expect(
        await items(<String, Object?>{'field': 'Expression', 'q': 'いぬ'}),
        isEmpty,
        reason: '读音不在 Expression 字段里',
      );
      final List<Object?> cards = await items(<String, Object?>{
        'q': '魚',
        'mode': 'cards',
      });
      expect((cards.first! as Map<String, Object?>)['cardId'], isNotNull);
      await expectLater(
        _call(
          routes,
          'GET',
          '$kSrsCtlRoot/notes',
          body: <String, Object?>{'mode': 'x'},
        ),
        _failure(400),
      );

      final Map<String, Object?> note =
          (await _call(routes, 'GET', '$kSrsCtlRoot/notes/$fish'))!
              as Map<String, Object?>;
      expect((note['fields']! as Map<String, Object?>)['Expression'], '魚');
      expect(note['cards'], isNotEmpty);
      await expectLater(
        _call(routes, 'GET', '$kSrsCtlRoot/notes/nope'),
        _failure(404),
      );
    });

    test('stats 与统计页同源：新卡数、今日复习', () async {
      final String card = (await store.cardsOfNote(fish)).first.id;
      await store.answer(card, 3);
      final Map<String, Object?> s =
          (await _call(routes, 'GET', '$kSrsCtlRoot/stats'))!
              as Map<String, Object?>;
      expect((s['today']! as Map<String, Object?>)['reviews'], 1);
      expect((s['today']! as Map<String, Object?>)['good'], 1);
      final Map<String, Object?> cards = s['cards']! as Map<String, Object?>;
      expect(cards['total'], greaterThanOrEqualTo(2));
      await expectLater(
        _call(
          routes,
          'GET',
          '$kSrsCtlRoot/stats',
          body: <String, Object?>{'deck': 'no such deck'},
        ),
        _failure(404),
      );
    });
  });

  group('重复笔记', () {
    late FushiDatabase db;
    late SrsDbStore store;
    late List<CtlRoute> routes;
    late int changed;

    setUp(() async {
      (db, store) = await openSrsTestStore();
      changed = 0;
      routes = _routesFor(store, changed: () => changed++);
    });
    tearDown(() => db.close());

    test('conflicts 列出建议；merge 后被吸收的删除、复习历史并入、建议消失', () async {
      final String keep = await _addNote(store, '雪', 'ゆき');
      final String other = await _addNote(store, '雪', 'ゆき');
      final String keepCard = (await store.cardsOfNote(keep)).first.id;
      await store.answer(keepCard, 3);
      await store.answer((await store.cardsOfNote(other)).first.id, 1);

      final Map<String, Object?> list =
          (await _call(routes, 'GET', '$kSrsCtlRoot/conflicts'))!
              as Map<String, Object?>;
      expect(list['duplicates'], hasLength(1));

      await expectLater(
        _call(
          routes,
          'POST',
          '$kSrsCtlRoot/duplicates/merge',
          body: <String, Object?>{
            'keep': keep,
            'absorb': <String>[keep],
          },
        ),
        _failure(400),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '$kSrsCtlRoot/duplicates/merge',
          body: <String, Object?>{
            'keep': keep,
            'absorb': <String>['nope'],
          },
        ),
        _failure(404),
      );

      final Map<String, Object?> r =
          (await _call(
                routes,
                'POST',
                '$kSrsCtlRoot/duplicates/merge',
                body: <String, Object?>{
                  'keep': keep,
                  'absorb': <String>[other],
                },
              ))!
              as Map<String, Object?>;
      expect(r['linkedCards'], 1);
      expect(changed, 1);
      final SrsNoteView? absorbed = await store.note(other);
      expect(absorbed == null || absorbed.deletedAt != null, isTrue);
      expect((await store.history(keepCard)).effective, hasLength(2));
      expect(
        ((await _call(routes, 'GET', '$kSrsCtlRoot/conflicts'))!
            as Map<String, Object?>)['duplicates'],
        isEmpty,
      );
    });

    test('dismiss：少于两条 400；标记后建议消失、两条都在', () async {
      final String a = await _addNote(store, '雨', 'あめ');
      final String b = await _addNote(store, '雨', 'あめ');
      await expectLater(
        _call(
          routes,
          'POST',
          '$kSrsCtlRoot/duplicates/dismiss',
          body: <String, Object?>{
            'notes': <String>[a],
          },
        ),
        _failure(400),
      );
      await _call(
        routes,
        'POST',
        '$kSrsCtlRoot/duplicates/dismiss',
        body: <String, Object?>{
          'notes': <String>[a, b],
        },
      );
      expect(await store.duplicateNoteGroups(), isEmpty);
      expect((await store.note(b))!.deletedAt, isNull);
    });
  });

  group('同步 v2 冲突', () {
    test('被扣住的删除：未知 id 404；keep 没确认 400；delete 后笔记卡隐藏、冲突消失', () async {
      final _TwoDevices env = await _TwoDevices.open();
      addTearDown(env.close);
      final String noteId = await _addNote(env.a, '魚', 'さかな');
      await env.syncAll();
      await env.a.deleteNote(noteId);
      await env.b.updateNote(
        noteId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Sentence'): '離線編集',
        },
      );
      await env.syncAll();
      final List<CtlRoute> routes = _routesFor(env.b);

      final Map<String, Object?> list =
          (await _call(routes, 'GET', '$kSrsCtlRoot/conflicts'))!
              as Map<String, Object?>;
      final Map<String, Object?> held =
          (list['held']! as List<Object?>).single! as Map<String, Object?>;
      expect(held['kind'], 'delete_edit');
      expect(held['label'], '魚');
      final String id = held['id']! as String;

      await expectLater(
        _call(routes, 'POST', '$kSrsCtlRoot/conflicts/held/nope/delete'),
        _failure(404),
      );
      await expectLater(
        _call(routes, 'POST', '$kSrsCtlRoot/conflicts/held/$id/keep'),
        _failure(400),
      );
      final Map<String, Object?> r =
          (await _call(
                routes,
                'POST',
                '$kSrsCtlRoot/conflicts/held/$id/delete',
              ))!
              as Map<String, Object?>;
      expect(r['deleted'], isTrue);
      expect(r['deletedAt'], isA<int>());
      expect((await env.b.cardsOfNote(noteId)).single.hidden, isTrue);
      expect(await env.b.sync2Conflicts(), isEmpty);
    });

    test('被扣住的删除：keep 带 confirm → 条目保留、冲突消失', () async {
      final _TwoDevices env = await _TwoDevices.open();
      addTearDown(env.close);
      final String noteId = await _addNote(env.a, '鳥', 'とり');
      await env.syncAll();
      await env.a.deleteNote(noteId);
      await env.b.updateNote(
        noteId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Sentence'): '離線編集',
        },
      );
      await env.syncAll();
      final List<CtlRoute> routes = _routesFor(env.b);
      final String id = (await env.b.sync2Conflicts()).single['id']! as String;
      await _call(
        routes,
        'POST',
        '$kSrsCtlRoot/conflicts/held/$id/keep',
        body: <String, Object?>{'confirm': true},
      );
      expect(await env.b.sync2Conflicts(), isEmpty);
      expect((await env.b.cardsOfNote(noteId)).single.hidden, isFalse);
    });

    test('被覆盖的标志：keep=replaced 写被覆盖的值、冲突消失；参数校验', () async {
      final _TwoDevices env = await _TwoDevices.open();
      addTearDown(env.close);
      final String noteId = await _addNote(env.a, '花', 'はな');
      await env.syncAll();
      final String card = (await env.a.cardsOfNote(noteId)).single.id;
      await env.a.setFlag(card, 1);
      await env.b.setFlag(card, 2);
      await env.syncAll();
      final List<CtlRoute> routes = _routesFor(env.b);
      final Map<String, Object?> list =
          (await _call(routes, 'GET', '$kSrsCtlRoot/conflicts'))!
              as Map<String, Object?>;
      final Map<String, Object?> f =
          (list['fields']! as List<Object?>).single! as Map<String, Object?>;
      expect(f['kind'], 'card');
      final Object? current = (f['current']! as Map<String, Object?>)['value'];
      final Object? replaced =
          (f['replaced']! as Map<String, Object?>)['value'];
      expect(<Object?>{current, replaced}, <Object?>{1, 2});

      await expectLater(
        _call(
          routes,
          'POST',
          '$kSrsCtlRoot/conflicts/fields/resolve',
          body: <String, Object?>{
            'kind': 'card',
            'entity': card,
            'key': f['key'],
            'keep': 'both',
          },
        ),
        _failure(400),
      );
      await expectLater(
        _call(
          routes,
          'POST',
          '$kSrsCtlRoot/conflicts/fields/resolve',
          body: <String, Object?>{
            'kind': 'card',
            'entity': 'nope',
            'key': f['key'],
            'keep': 'current',
          },
        ),
        _failure(404),
      );
      final Map<String, Object?> r =
          (await _call(
                routes,
                'POST',
                '$kSrsCtlRoot/conflicts/fields/resolve',
                body: <String, Object?>{
                  'kind': 'card',
                  'entity': card,
                  'key': f['key'],
                  'keep': 'replaced',
                },
              ))!
              as Map<String, Object?>;
      expect(r['value'], replaced);
      expect(r['previous'], current);
      expect(await env.b.syncConflicts(), isEmpty);
      expect((await env.b.cardRow(card))!.flag, replaced);
    });
  });
}
