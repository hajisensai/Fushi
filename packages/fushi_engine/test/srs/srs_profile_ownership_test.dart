// 一份 srs.db 里开着两份 profile 时，拿 A 的 SrsDbStore 给出 B 的实体 ID：读不到、写不落，与「哪里都没有的
// ID」同样对待（docs/bugs/ 里「复习库按 id 的读写不看 profile」那一条）。
//
// - 读：笔记 / 笔记类型 / 牌组 / 卡片 / 复习历史 / 修改记录 / 修改历史，逐个入口；
// - 写：SrsDbStore 的每个按 ID 的写入口（改字段、删笔记、卡片标志、手动排程、作答、牌组、彻底清除、合并重复、
//   笔记类型……）各跑一遍，之后 B 名下的每一行（含操作日志、缓存、摘要桶）逐行不变，A 名下也没有多出指向
//   B 的行、没有多出操作；
// - 远程复习的主机路由（srs_remote_store_routes.dart）：点名 A、参数里给 B 的 ID，同样读不到、写不落；
// - 正常路径：同样的入口对本 profile 自己的 ID 照常生效。
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String kA = '01928c3e-0000-7000-8000-0000000000a1';
const String kB = '01928c3e-0000-7000-8000-0000000000b2';

/// 一份 profile 里造好的数据（[SrsDbStore] 的各类实体各一个）。
class _Side {
  _Side(this.store);

  final SrsDbStore store;
  late final String deck;
  late final String note;
  late final String twin;
  late final String card;
  late final String log;

  String get uid => store.profileUid;
  String get type => store.lapisNoteTypeId;
  String get expression => srsLapisFieldId(uid, 'Expression');

  /// 这一份里测试会用到的全部实体 ID。
  Set<String> get ids => <String>{
    uid,
    deck,
    store.defaultDeckId,
    note,
    twin,
    card,
    log,
    type,
  };

  Future<void> seed(String word) async {
    deck = await store.createDeck('牌组 $word');
    note = await store.createNote(
      noteTypeId: type,
      fieldsById: <String, String>{expression: word},
      deckId: deck,
      tags: <String>['tag-$word'],
    );
    twin = await store.createNote(
      noteTypeId: type,
      fieldsById: <String, String>{expression: word},
      deckId: deck,
    );
    card = (await store.cardsOfNote(note)).first.id;
    log = (await store.answer(card, 3)).id;
    await store.setCss(type, '.card { color: red; } /* $word */');
    await store.setDayRolloverHour(5);
    await store.setDeckCollapsed(deck, true);
  }
}

class _Env {
  _Env(this.db, this.a, this.b);

  final SrsDatabase db;
  final _Side a;
  final _Side b;

  static Future<_Env> open() async {
    final SrsStorage st = await openTestSrsStorage();
    int clock = DateTime.utc(2026, 11, 11, 12).millisecondsSinceEpoch;
    Future<_Side> side(String uid, String word) async {
      final _Side s = _Side(
        await SrsDbStore.open(
          db: st.db,
          core: st.core,
          profileUid: uid,
          deviceId: 'dev',
          engine: const SrsFakeEngine(),
          trustedClock: SrsTrustedClock(
            wallClockMs: () => clock += 1000,
            bootClockMs: () => clock,
            bootId: 'boot',
          ),
          fallbackRolloverHour: () => 4,
          localOffsetMin: () => 0,
        ),
      );
      await s.seed(word);
      return s;
    }

    return _Env(st.db, await side(kA, '魚'), await side(kB, '鳥'));
  }

  /// srs.db 里带 `profile_uid` 列的表 → 它的列（现查，不手抄）。
  Future<Map<String, List<String>>> _tables() async {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT m.name AS t, p.name AS c FROM sqlite_master m, '
              "pragma_table_info(m.name) p WHERE m.type = 'table' "
              'AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) q '
              "WHERE q.name = 'profile_uid') ORDER BY m.name, p.cid",
            )
            .get()) {
      (out[r.read<String>('t')] ??= <String>[]).add(r.read<String>('c'));
    }
    return out;
  }

  /// [uid] 名下的每一行（表 → 排好序的行文本）：操作日志、投影、缓存、摘要桶、同步元数据全在里面。
  /// [skip] 里的表不比（本机时钟之类写不写操作都会前进的状态）。每列取 `quote(...)` 的字面量：BLOB（ID、
  /// 载荷、链哈希）读成 `X'..'` 文本，逐字节可比，也不把 ID 的存储字节交回 Dart。
  Future<Map<String, List<String>>> dump(
    String uid, {
    Set<String> skip = const <String>{},
  }) async {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final MapEntry<String, List<String>> t in (await _tables()).entries) {
      if (skip.contains(t.key)) continue;
      final String columns = <String>[
        for (final String c in t.value) 'quote("$c") AS "$c"',
      ].join(', ');
      final List<String> rows = <String>[
        for (final QueryRow r
            in await db
                .customSelect(
                  'SELECT $columns FROM "${t.key}" WHERE profile_uid = ?',
                  variables: <Variable<Object>>[
                    Variable<String>(uid, srsIdType),
                  ],
                )
                .get())
          r.data.entries
              .map((MapEntry<String, Object?> e) => '${e.key}=${e.value}')
              .join(' | '),
      ]..sort();
      if (rows.isNotEmpty) out[t.key] = rows;
    }
    return out;
  }

  Future<int> _count(String sql, String uid, Iterable<String> ids) async {
    final List<String> list = ids.toList();
    return (await db
            .customSelect(
              '$sql (${List<String>.filled(list.length, '?').join(',')})',
              variables: <Variable<Object>>[
                Variable<String>(uid, srsIdType),
                for (final String id in list) Variable<String>(id, srsIdType),
              ],
            )
            .getSingle())
        .read<int>('c');
  }

  /// [uid] 名下指向 [ids] 的投影行数（身份记录 / 修改记录 / 复习日志 / 两张缓存）。
  Future<int> rowsPointingAt(String uid, Iterable<String> ids) async {
    int n = 0;
    for (final String sql in <String>[
      'SELECT COUNT(*) AS c FROM srs_entities WHERE profile_uid = ? AND id IN',
      'SELECT COUNT(*) AS c FROM srs_field_edits WHERE profile_uid = ? '
          'AND entity_id IN',
      'SELECT COUNT(*) AS c FROM srs_review_logs WHERE profile_uid = ? '
          'AND card_id IN',
      'SELECT COUNT(*) AS c FROM srs_notes_cache WHERE profile_uid = ? '
          'AND id IN',
      'SELECT COUNT(*) AS c FROM srs_cards_cache WHERE profile_uid = ? '
          'AND id IN',
    ]) {
      n += await _count(sql, uid, ids);
    }
    return n;
  }

  /// [uid] 的操作日志条数。
  Future<int> ops(String uid) async =>
      (await db
              .customSelect(
                'SELECT COUNT(*) AS c FROM sync2_ops WHERE profile_uid = ?',
                variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
              )
              .getSingle())
          .read<int>('c');
}

/// 一次调用的结局：正常返回（连同返回值的文本）或抛了哪一类错。
Future<String> _outcome(Future<Object?> Function() run) async {
  try {
    return 'ok ${await run()}';
  } on StateError {
    return 'StateError';
  } on ArgumentError {
    return 'ArgumentError';
  } on SrsRemoteStoreError catch (e) {
    return 'remote ${e.status} ${e.code}';
  }
}

/// 一条写入口：拿 [s]（调用方的 store）对 [x]（别人的那份数据，或一组哪里都没有的 ID）下手。
typedef _Write = Future<Object?> Function(SrsDbStore s, _Side own, _Target x);

/// 被下手的一组 ID。
class _Target {
  const _Target({
    required this.uid,
    required this.deck,
    required this.note,
    required this.twin,
    required this.card,
    required this.log,
    required this.type,
    required this.expression,
  });

  factory _Target.of(_Side s) => _Target(
    uid: s.uid,
    deck: s.deck,
    note: s.note,
    twin: s.twin,
    card: s.card,
    log: s.log,
    type: s.type,
    expression: s.expression,
  );

  final String uid;
  final String deck;
  final String note;
  final String twin;
  final String card;
  final String log;
  final String type;
  final String expression;
}

SrsReviewLog _logOn(SrsReviewLog like, String cardId, String profileUid) =>
    SrsReviewLog.fromJson(<String, Object?>{
      ...like.toJson(),
      'id': uuidV7(nowMs: like.occurredAt + 1),
      'p': profileUid,
      'card': cardId,
    });

final Map<String, _Write> _writes = <String, _Write>{
  'editField 笔记字段': (SrsDbStore s, _Side own, _Target x) => s.editField(
    SrsEntityKind.note,
    x.note,
    SrsFieldKeys.noteField(x.expression),
    '被改',
  ),
  'editFields 笔记标签': (SrsDbStore s, _Side own, _Target x) =>
      s.editFields(SrsEntityKind.note, x.note, <String, Object?>{
        SrsFieldKeys.noteTags: <String>['串了'],
      }),
  'editFieldsBatch 笔记 + 卡片': (SrsDbStore s, _Side own, _Target x) =>
      s.editFieldsBatch(<SrsFieldChange>[
        SrsFieldChange(
          SrsEntityKind.note,
          x.note,
          SrsFieldKeys.noteField(x.expression),
          '被改',
        ),
        SrsFieldChange(SrsEntityKind.card, x.card, SrsFieldKeys.flag, 3),
      ]),
  'writeEdits 修改记录': (SrsDbStore s, _Side own, _Target x) =>
      s.writeEdits(<SrsEditSpec>[
        SrsEditSpec(SrsEntityKind.note, x.note, SrsFieldKeys.noteDeck, x.deck),
        SrsEditSpec(SrsEntityKind.deck, x.deck, SrsFieldKeys.name, '被改名'),
      ]),
  'writeEdits 同 ID 的身份记录': (SrsDbStore s, _Side own, _Target x) => s.writeEdits(
    const <SrsEditSpec>[],
    records: <SrsEntityRecord>[
      SrsEntityRecord(
        id: x.note,
        profileUid: s.profileUid,
        kind: SrsEntityKind.note,
        payload: <String, Object?>{
          'noteTypeId': own.type,
          'guid': 'stolen',
          'createdAt': 1,
        },
      ),
    ],
  ),
  'updateNote': (SrsDbStore s, _Side own, _Target x) => s.updateNote(
    x.note,
    fieldsById: <String, String>{x.expression: '被改'},
    tags: <String>['串了'],
  ),
  'deleteNote': (SrsDbStore s, _Side own, _Target x) => s.deleteNote(x.note),
  'restoreNote': (SrsDbStore s, _Side own, _Target x) => s.restoreNote(x.note),
  'setSuspended': (SrsDbStore s, _Side own, _Target x) =>
      s.setSuspended(x.card, true),
  'buryUntil': (SrsDbStore s, _Side own, _Target x) => s.buryUntil(x.card, 99),
  'setFlag': (SrsDbStore s, _Side own, _Target x) => s.setFlag(x.card, 2),
  'moveCard 别人的卡': (SrsDbStore s, _Side own, _Target x) =>
      s.moveCard(x.card, own.deck),
  'resetCard': (SrsDbStore s, _Side own, _Target x) => s.resetCard(x.card),
  'resetCards': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.resetCards(<String>[x.card])).length,
  'setDueDay': (SrsDbStore s, _Side own, _Target x) => s.setDueDay(x.card, 7),
  'setDueDays': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.setDueDays(<String, int>{x.card: 7})).length,
  'undo': (SrsDbStore s, _Side own, _Target x) => s.undo(x.card, x.log),
  'undoLogs': (SrsDbStore s, _Side own, _Target x) =>
      s.undoLogs(<(String, String)>[(x.card, x.log)]),
  'answer': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.answer(x.card, 3)).cardId,
  'answerAndStudy': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.answerAndStudy(x.card, 1, studyDeckId: own.deck)).log.cardId,
  'importEvents 日志': (SrsDbStore s, _Side own, _Target x) async {
    final SrsReviewLog like = (await own.store.logsOfCards(<String>[
      own.card,
    ]))[own.card]!.first;
    await s.importEvents(<SrsEvent>[
      SrsLogEvent(_logOn(like, x.card, s.profileUid)),
    ]);
    return null;
  },
  'setNewCardPositions': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.setNewCardPositions(<String, int>{x.card: 3})).length,
  'deleteDeck': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.deleteDeck(x.deck)).length,
  'deleteDeck 连卡片': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.deleteDeck(x.deck, deleteCards: true)).length,
  'moveDeck': (SrsDbStore s, _Side own, _Target x) => s.moveDeck(x.deck, null),
  'placeDeck 到别人的牌组下': (SrsDbStore s, _Side own, _Target x) =>
      s.placeDeck(own.deck, parentId: x.deck),
  'setDeckCollapsed': (SrsDbStore s, _Side own, _Target x) =>
      s.setDeckCollapsed(x.deck, false),
  'rescheduleDeck': (SrsDbStore s, _Side own, _Target x) =>
      s.rescheduleDeck(x.deck),
  'extendTodayLimits': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.extendTodayLimits(x.deck, newCards: 5)).newCards,
  'sync2Purge 笔记': (SrsDbStore s, _Side own, _Target x) =>
      s.sync2PurgeMany(SrsEntityKind.note, <String>[x.note]),
  'sync2Purge 卡片': (SrsDbStore s, _Side own, _Target x) =>
      s.sync2PurgeMany(SrsEntityKind.card, <String>[x.card]),
  'resolveConflict': (SrsDbStore s, _Side own, _Target x) =>
      s.resolveConflict(SrsEntityKind.card, x.card, SrsFieldKeys.flag, 4),
  'mergeNotes 吸收别人的笔记': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.mergeNotes(
        keepId: own.note,
        absorbIds: <String>[x.note],
      )).linkedCards,
  'mergeNotes 两条都是别人的': (SrsDbStore s, _Side own, _Target x) async =>
      (await s.mergeNotes(
        keepId: x.note,
        absorbIds: <String>[x.twin],
      )).linkedCards,
  'dismissDuplicates 两条都是别人的': (SrsDbStore s, _Side own, _Target x) =>
      s.dismissDuplicates(<String>[x.note, x.twin]),
  'dismissDuplicates 自己的 + 别人的': (SrsDbStore s, _Side own, _Target x) =>
      s.dismissDuplicates(<String>[own.twin, x.twin]),
  'changeNoteType': (SrsDbStore s, _Side own, _Target x) => s.changeNoteType(
    noteIds: <String>[x.note],
    targetTypeId: s.fushiCardNoteTypeId,
    fieldMap: const <String, String?>{},
    templateMap: const <String, String?>{},
  ),
  'renameNoteType': (SrsDbStore s, _Side own, _Target x) =>
      s.renameNoteType(x.type, '被改名'),
  'setCss': (SrsDbStore s, _Side own, _Target x) => s.setCss(x.type, '.x{}'),
  'addField': (SrsDbStore s, _Side own, _Target x) => s.addField(x.type, '多的'),
  'deleteNoteType': (SrsDbStore s, _Side own, _Target x) =>
      s.deleteNoteType(x.type),
  'editField profile 设置': (SrsDbStore s, _Side own, _Target x) => s.editField(
    SrsEntityKind.profile,
    x.uid,
    SrsFieldKeys.dayRolloverHour,
    9,
  ),
};

/// 哪里都没有的一组 ID（[n] 区分各用例，免得上一条留下的悬空记录影响下一条）。
_Target _nowhere(int n) {
  String id(String what) => uuidV5(srsNamespace, 'nowhere/$n/$what');
  return _Target(
    uid: id('profile'),
    deck: id('deck'),
    note: id('note'),
    twin: id('twin'),
    card: id('card'),
    log: id('log'),
    type: id('type'),
    expression: id('field'),
  );
}

/// 经远程复习的主机路由走一遍 JSON：`(HTTP 状态, 回包)`。
Future<(int, Map<String, Object?>)> _remote(
  SrsRemoteStoreService service,
  String profile,
  String op,
  Map<String, Object?> args, {
  String? request,
}) async {
  final shelf.Response res = await handleSrsRemoteStoreRequest(
    service,
    shelf.Request(
      'POST',
      Uri.parse('http://host/api/srs/remote/call'),
      body: jsonEncode(<String, Object?>{
        'profile': profile,
        'op': op,
        'args': args,
        'request': ?request,
      }),
    ),
    'POST',
    '/api/srs/remote/call',
  );
  return (
    res.statusCode,
    (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>(),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // A 的写入不会让这几张表里 A 自己的行变化之外再有别的差别：本机时钟 / 修订号（写不写操作都会存一次）。
  const Set<String> ownVolatile = <String>{'srs_local_state', 'sync2_self'};

  group('别的 profile 的 ID：读不到', () {
    late _Env env;
    late SrsDbStore a;
    late _Side b;

    setUp(() async {
      env = await _Env.open();
      a = env.a.store;
      b = env.b;
    });

    test('笔记', () async {
      expect(await a.note(b.note), isNull);
      expect(await a.notes(<String>[b.note, env.a.note]), <String, Object?>{
        b.note: isNull,
        env.a.note: isNotNull,
      });
      expect(
        await a.entitySources(SrsEntityKind.note, ids: <String>[b.note]),
        isEmpty,
      );
      expect(
        await a.noteFieldKeyValues(<String>[b.note], SrsFieldKeys.noteDeck),
        isEmpty,
      );
      expect(await a.noteFieldKeyPrefixValues(<String>[b.note], 'f/'), isEmpty);
    });

    test('笔记类型', () async {
      expect(await a.noteType(b.type), isNull);
      expect(await a.noteTypesById(<String>[b.type]), <String, Object?>{
        b.type: isNull,
      });
      expect(
        await a.entitySources(SrsEntityKind.noteType, ids: <String>[b.type]),
        isEmpty,
      );
      expect(await a.noteIdsOfType(b.type), isEmpty);
      expect((await a.noteCountsByType())[b.type], isNull);
    });

    test('牌组', () async {
      expect(
        await a.entitySources(SrsEntityKind.deck, ids: <String>[b.deck]),
        isEmpty,
      );
      expect(await a.deckSummary(b.deck), isNull);
      expect(await a.studyState(b.deck), isNull);
      expect(await a.cardIdsInDecks(<String>{b.deck}), isEmpty);
    });

    test('卡片', () async {
      expect(await a.cardRow(b.card), isNull);
      expect(await a.cardRows(<String>[b.card, env.a.card]), hasLength(1));
      expect(await a.cardsOfNote(b.note), isEmpty);
      expect((await a.cardsOfNotes(<String>[b.note]))[b.note], isEmpty);
      expect(await a.cardDetail(b.card), isNull);
      expect(await a.renderCard(b.card), isNull);
      await expectLater(a.preview(b.card), throwsStateError);
    });

    test('复习历史', () async {
      expect((await a.history(b.card)).all, isEmpty);
      expect((await a.histories(<String>[b.card]))[b.card]!.all, isEmpty);
      expect((await a.logsOfCards(<String>[b.card]))[b.card], isNull);
    });

    test('修改记录与修改历史', () async {
      for (final (SrsEntityKind kind, String id) in <(SrsEntityKind, String)>[
        (SrsEntityKind.note, b.note),
        (SrsEntityKind.card, b.card),
        (SrsEntityKind.deck, b.deck),
        (SrsEntityKind.noteType, b.type),
        (SrsEntityKind.profile, b.uid),
      ]) {
        // B 自己读得到（否则下面的「读不到」什么也没证明）。
        if (kind != SrsEntityKind.card) {
          expect(
            (await b.store.entityEdits(kind, id)).keys,
            isNotEmpty,
            reason: 'B 的 ${kind.wire} 应有修改记录',
          );
        }
        expect(
          (await a.entityEdits(kind, id)).keys,
          isEmpty,
          reason: kind.wire,
        );
        expect(
          (await a.entityEditsMany(kind, <String>[id]))[id]!.keys,
          isEmpty,
          reason: kind.wire,
        );
        expect(await a.editHistory(kind, id), isEmpty, reason: kind.wire);
        expect(
          await a.syncConflicts(entity: (kind: kind, id: id)),
          isEmpty,
          reason: kind.wire,
        );
      }
      expect(await b.store.editHistory(SrsEntityKind.note, b.note), isNotEmpty);
    });
  });

  group('别的 profile 的 ID：写不落', () {
    for (final MapEntry<String, _Write> w in _writes.entries) {
      test(w.key, () async {
        final _Env env = await _Env.open();
        final SrsDbStore a = env.a.store;
        final Map<String, List<String>> bBefore = await env.dump(kB);
        final Map<String, List<String>> aBefore = await env.dump(
          kA,
          skip: ownVolatile,
        );
        final int opsBefore = await env.ops(kA);

        final String got = await _outcome(
          () => w.value(a, env.a, _Target.of(env.b)),
        );

        expect(await env.dump(kB), bBefore, reason: 'B 名下的行被动了（$got）');
        expect(
          await env.rowsPointingAt(kA, env.b.ids),
          0,
          reason: 'A 名下多出了指向 B 的行（$got）',
        );
        // 「不是重复」是成对写的：别人那一条不落，自己笔记上那一条（键里带着对方的 ID）照写——它记在 A 自己的实体上，
        // 与给一个哪里都没有的 ID 时一样。其余入口 A 这边一条操作都不多。
        if (w.key != 'dismissDuplicates 自己的 + 别人的') {
          expect(await env.ops(kA), opsBefore, reason: 'A 多写了操作（$got）');
          expect(
            await env.dump(kA, skip: ownVolatile),
            aBefore,
            reason: 'A 自己的数据被动了（$got）',
          );
        }
        // B 的 store 读到的也还是原样。
        final SrsNoteView n = (await env.b.store.note(env.b.note))!;
        expect(n.deletedAt, isNull);
        expect(n.field(env.b.expression), '鳥');
        expect(n.tags, <String>['tag-鳥']);
        final SrsCardCacheRow c = (await env.b.store.cardRow(env.b.card))!;
        expect(c.hidden, isFalse);
        expect(c.suspended, isFalse);
        expect(c.lastLogId, env.b.log);

        // 对调用方：与「哪里都没有的 ID」同一类结局（正常返回 / 抛同一类错）。不比返回值——没人的 ID 照旧落一条
        // 悬空记录，返回的是那条记录。上面的写入什么都没落，这份库还是原样，接着用。
        String kind(String o) => o.startsWith('ok') ? 'ok' : o;
        final String absent = await _outcome(
          () => w.value(a, env.a, _nowhere(0)),
        );
        expect(kind(got), kind(absent), reason: '别人的 ID：$got；不存在的 ID：$absent');
      });
    }

    test('改别人的字段：返回的是「没写出任何修改记录」', () async {
      final _Env env = await _Env.open();
      final SrsDbStore a = env.a.store;
      final _Side b = env.b;
      expect(
        await a.editFields(SrsEntityKind.note, b.note, <String, Object?>{
          SrsFieldKeys.noteField(b.expression): '被改',
        }),
        isEmpty,
      );
      // 一批里自己的照写、别人的不写，返回的只有写出的那些。
      final List<SrsFieldEdit> out = await a.editFieldsBatch(<SrsFieldChange>[
        SrsFieldChange(SrsEntityKind.card, b.card, SrsFieldKeys.flag, 3),
        SrsFieldChange(SrsEntityKind.card, env.a.card, SrsFieldKeys.flag, 3),
      ]);
      expect(out.map((SrsFieldEdit e) => e.entityId), <String>[env.a.card]);
      expect((await a.cardRow(env.a.card))!.flag, 3);
      expect((await b.store.cardRow(b.card))!.flag, 0);
    });
  });

  group('自己的 ID：照常生效', () {
    for (final MapEntry<String, _Write> w in _writes.entries) {
      // 这几条的参数形状只对「别人的 ID」有意义（同一份里的两条 / 同一份里的身份记录），正常路径另有专门的测试。
      if (const <String>{
        'writeEdits 同 ID 的身份记录',
        'placeDeck 到别人的牌组下',
        'mergeNotes 吸收别人的笔记',
        'dismissDuplicates 自己的 + 别人的',
        'restoreNote',
        'undoLogs',
        'answerAndStudy',
        'resetCards',
        'setDueDays',
        'deleteDeck 连卡片',
        'changeNoteType',
        'importEvents 日志',
        'setNewCardPositions',
        'moveDeck',
        'rescheduleDeck',
        // 还有笔记在用的笔记类型删不掉（StateError），与归属无关。
        'deleteNoteType',
      }.contains(w.key)) {
        continue;
      }
      test(w.key, () async {
        final _Env env = await _Env.open();
        final int opsBefore = await env.ops(kA);
        final Map<String, List<String>> bBefore = await env.dump(kB);
        final String got = await _outcome(
          () => w.value(env.a.store, env.a, _Target.of(env.a)),
        );
        expect(got, startsWith('ok'), reason: got);
        expect(
          await env.ops(kA),
          greaterThan(opsBefore),
          reason: '对自己的 ID 没写出操作（$got）',
        );
        expect(await env.dump(kB), bBefore);
      });
    }

    test('两份 profile 各改各的，互不可见', () async {
      final _Env env = await _Env.open();
      for (final _Side s in <_Side>[env.a, env.b]) {
        await s.store.updateNote(
          s.note,
          fieldsById: <String, String>{s.expression: '改-${s.uid}'},
        );
        await s.store.setFlag(s.card, 1);
        expect((await s.store.note(s.note))!.field(s.expression), '改-${s.uid}');
        expect((await s.store.cardRow(s.card))!.flag, 1);
        expect((await s.store.history(s.card)).all, hasLength(1));
        expect(
          (await s.store.mergeNotes(
            keepId: s.note,
            absorbIds: <String>[s.twin],
          )).linkedCards,
          greaterThan(0),
        );
        expect((await s.store.note(s.twin))!.deletedAt, isNotNull);
      }
    });
  });

  group('远程复习的主机路由：点名 A、给 B 的 ID', () {
    late _Env env;
    late SrsRemoteStoreService service;
    late _Side b;

    setUp(() async {
      env = await _Env.open();
      b = env.b;
      service = SrsRemoteStoreService(
        readStore: () async => env.a.store,
        readMedia: (String name) async => null,
        readProfile: (String uid) async => switch (uid) {
          kA => env.a.store,
          kB => env.b.store,
          _ => null,
        },
      );
    });

    Future<Object?> read(String op, Map<String, Object?> args) async {
      final (int status, Map<String, Object?> body) = await _remote(
        service,
        kA,
        op,
        args,
      );
      expect(status, 200, reason: '$op → $body');
      return body['result'];
    }

    test('读：与不存在的 ID 同样的回包', () async {
      expect(
        await read('notes', <String, Object?>{
          'ids': <String>[b.note],
        }),
        isEmpty,
      );
      expect(await read('cardRow', <String, Object?>{'card': b.card}), isNull);
      expect(
        await read('cardRows', <String, Object?>{
          'cards': <String>[b.card],
        }),
        isEmpty,
      );
      expect(
        await read('cardsOfNote', <String, Object?>{'note': b.note}),
        isEmpty,
      );
      expect(
        await read('cardDetail', <String, Object?>{'card': b.card}),
        isNull,
      );
      expect(
        await read('renderCard', <String, Object?>{'card': b.card}),
        isNull,
      );
      expect(
        await read('noteTypeSources', <String, Object?>{
          'ids': <String>[b.type],
        }),
        isEmpty,
      );
      expect(
        await read('noteTypeRefs', <String, Object?>{
          'ids': <String>[b.type],
        }),
        isEmpty,
      );
      expect(
        await read('deckSummary', <String, Object?>{'deck': b.deck}),
        isNull,
      );
      expect(
        await read('entityEdits', <String, Object?>{
          'kind': 'note',
          'id': b.note,
        }),
        isEmpty,
      );
      expect(
        await read('editHistory', <String, Object?>{
          'kind': 'note',
          'id': b.note,
        }),
        isEmpty,
      );
      expect(
        ((await read('history', <String, Object?>{'card': b.card}))!
            as Map<String, Object?>)['all'],
        isEmpty,
      );
      expect(
        await read('noteIdsOfType', <String, Object?>{'type': b.type}),
        isEmpty,
      );
      // 预览：没有这张卡时主机报 failed，别人的卡也一样。
      final (int status, Map<String, Object?> body) = await _remote(
        service,
        kA,
        'preview',
        <String, Object?>{'card': b.card},
      );
      final (int status0, Map<String, Object?> body0) = await _remote(
        service,
        kA,
        'preview',
        <String, Object?>{'card': _nowhere(0).card},
      );
      expect((status, body['error']), (status0, body0['error']));
    });

    test('写：B 逐行不变，A 没多出操作', () async {
      final Map<String, List<String>> bBefore = await env.dump(kB);
      final int opsBefore = await env.ops(kA);
      int request = 0;
      final Map<String, Map<String, Object?>>
      writes = <String, Map<String, Object?>>{
        'updateNote': <String, Object?>{
          'note': b.note,
          'fields': <String, String>{b.expression: '被改'},
        },
        'deleteNote': <String, Object?>{'note': b.note},
        'restoreNote': <String, Object?>{'note': b.note},
        'setSuspended': <String, Object?>{'card': b.card, 'value': true},
        'buryUntil': <String, Object?>{'card': b.card, 'day': 99},
        'setFlag': <String, Object?>{'card': b.card, 'flag': 2},
        'moveCard': <String, Object?>{'card': b.card, 'deck': env.a.deck},
        'resetCard': <String, Object?>{'card': b.card},
        'resetCards': <String, Object?>{
          'cards': <String>[b.card],
        },
        'setDueDays': <String, Object?>{
          'days': <String, int>{b.card: 7},
        },
        'undo': <String, Object?>{'card': b.card, 'log': b.log},
        'answerAndStudy': <String, Object?>{
          'card': b.card,
          'rating': 3,
          'durationMs': 1000,
        },
        'rescheduleDeck': <String, Object?>{'deck': b.deck},
        'extendTodayLimits': <String, Object?>{'deck': b.deck, 'newCards': 5},
        'editFields': <String, Object?>{
          'kind': 'note',
          'id': b.note,
          'values': <String, Object?>{SrsFieldKeys.deleted: 1},
        },
        'editFieldsBatch': <String, Object?>{
          'changes': SrsRemoteWire.editSpecs(<SrsEditSpec>[
            SrsEditSpec(
              SrsEntityKind.card,
              b.card,
              SrsFieldKeys.suspended,
              true,
            ),
          ]),
        },
        'writeEdits': <String, Object?>{
          'specs': SrsRemoteWire.editSpecs(<SrsEditSpec>[
            SrsEditSpec(SrsEntityKind.note, b.note, SrsFieldKeys.deleted, 1),
          ]),
          'records': <Object?>[],
        },
        'changeNoteType': <String, Object?>{
          'notes': <String>[b.note],
          'target': env.a.store.fushiCardNoteTypeId,
          'fieldMap': <String, String?>{},
          'templateMap': <String, String?>{},
        },
      };
      final Map<String, (int, Object?)> got = <String, (int, Object?)>{};
      for (final MapEntry<String, Map<String, Object?>> w in writes.entries) {
        final (int status, Map<String, Object?> body) = await _remote(
          service,
          kA,
          w.key,
          w.value,
          request: 'r${request++}',
        );
        got[w.key] = (status, body['error']);
      }
      expect(await env.dump(kB), bBefore, reason: '$got');
      expect(await env.rowsPointingAt(kA, b.ids), 0, reason: '$got');
      expect(await env.ops(kA), opsBefore, reason: '$got');
      // 没有一条回 500（内部错误）：要么照「没有这个实体」正常返回，要么是与不存在同样的 4xx。
      expect(
        got.values.where(((int, Object?) r) => r.$1 >= 500),
        isEmpty,
        reason: '$got',
      );
    });
  });
}
