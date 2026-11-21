// 一份复习库里开着两份 profile 时，拿 A 的 SrsDbStore 给出 B 的实体 ID：读不到、写不落，与「哪里都没有的
// ID」同样对待（docs/bugs/ 里「复习库按 id 的读写不看 profile」那一条）。
//
// 新代（协议 4）里每个 profile 是一个独立的集合，B 的 ID 在 A 的集合里就是「哪里都没有的 ID」：A 的写入口拿它
// 下手时与拿一个真不存在的 ID 落同样的东西（悬空记录只记在 A 自己的集合里，B 永远看不到），所以这里比的是
// 「B 的整份真相（导出的全部操作）逐条不变、A 这边多出的操作与给不存在的 ID 时一样多」，不再看协议 3 那几张
// 带 `profile_uid` 列的共享表。内置实体（默认牌组、内置笔记类型）的 ID 在新代里与 profile 无关、两边相同，
// 它们是 A 自己的，不能当「B 的 ID」用：B 专属的笔记类型另建一个（按名字派生，两边名字不同）。
//
// - 读：笔记 / 笔记类型 / 牌组 / 卡片 / 复习历史 / 修改记录 / 修改历史，逐个入口；
// - 写：SrsDbStore 的每个按 ID 的写入口（改字段、删笔记、卡片标志、手动排程、作答、牌组、彻底清除、合并重复、
//   笔记类型……）各跑一遍，之后 B 的整份真相与视图逐条不变；对调用方的结局与给「哪里都没有的 ID」时同一类；A 为 B 的
//   ID **一条都不写**（只碰 B 的 ID 的入口：A 的日志长度不变；同时写自己实体的入口 [_writesOwnToo]：A 的真相里没有
//   指向 B 的 ID 的操作）。没人的 ID 照旧落悬空记录，B 的实体 ID 在写入口就被实体归属闸拦下（内核
//   `gen4/cmd/writes_owner.rs`，BUG-5005：A 的集合之后并进 B 时，悬空操作会对 B 的同名实体生效，所以不能写下）。
//   并入之后 B 不被改的端到端在 `srs_profile_ownership_merge_test.dart`；
// - 远程复习的主机路由（srs_remote_store_routes.dart）：点名 A、参数里给 B 的 ID，同样读不到、写不落；
// - 正常路径：同样的入口对本 profile 自己的 ID 照常生效。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
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

  /// 这一份专属的笔记类型（按名字派生，两份名字不同）。笔记仍用内置 Lapis（它的 ID 两份相同，是各自的）。
  late final String type;

  String get uid => store.profileUid;
  String get expression => srsLapisFieldId(uid, 'Expression');

  /// 这一份专属的全部实体 ID（不含两份共有的内置实体 ID）。
  Set<String> get ids => <String>{uid, deck, note, twin, card, log, type};

  Future<void> seed(String word) async {
    deck = await store.createDeck('牌组 $word');
    type = await store.createStockNoteType(SrsStockNoteType.basic, '类型 $word');
    note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{expression: word},
      deckId: deck,
      tags: <String>['tag-$word'],
    );
    twin = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
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

  final SrsCore db;
  final _Side a;
  final _Side b;

  static Future<_Env> open() async {
    final SrsStorage st = await openTestSrsStorage();
    int clock = DateTime.utc(2026, 11, 11, 12).millisecondsSinceEpoch;
    Future<_Side> side(String uid, String word) async {
      final _Side s = _Side(
        await SrsDbStore.open(
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

    return _Env(st.core, await side(kA, '魚'), await side(kB, '鳥'));
  }

  SrsDbStore _storeOf(String uid) => uid == a.uid ? a.store : b.store;

  /// [uid] 的整份真相：导出的全部操作（身份记录、修改记录、复习日志、不认识的事件；内核 `read events`），每条按
  /// 规范 JSON 成文、排好序，逐条可比。新代的派生层（卡片 / 笔记缓存、统计投影、摘要）是真相的纯函数，真相逐条
  /// 不变派生就不变；本机状态（时钟、修订号）不在真相里，不用像协议 3 那样另外跳过。
  Future<List<String>> dump(String uid) async => <String>[
    for (final SrsEvent e in await _storeOf(uid).exportAll())
      jsonEncode(e.toJson()),
  ]..sort();

  /// [uid] 的集合里本机写过的操作条数（内核 `status` 的 `nextSeq` − 1：本机日志的长度；每个集合只有本机一台设备）。
  /// [dump] 是投影后的值，同一字段改两次只剩最后一条，不能拿它数写了几次。也不能数 `status` 的 `ops`（日志里还
  /// 带内容的操作行数）：彻底清除在同一事务里把被清除实体的旧操作落成空洞（`weigh.rs` `execute_purges` →
  /// `Truth::advance_purge`），清除一条笔记追加 删除 + 清除 两条、空洞掉它更早的几条，`ops` 反而变少。
  Future<int> ops(String uid) async =>
      ((await _storeOf(uid).sync2Status())['nextSeq']! as int) - 1;

  /// [uid] 的整份真相里指向 [ids] 的操作条数（身份记录看它的 ID、修改记录看实体、复习日志看卡）。数「A 有没有为 B 的
  /// ID 写下东西」用：同时会写 A 自己实体的入口（[_writesOwnToo]）不能只数 [ops]。
  Future<int> pointingAt(String uid, Set<String> ids) async {
    int n = 0;
    for (final SrsEvent e in await _storeOf(uid).exportAll()) {
      final String? target = switch (e) {
        SrsEntityEvent(:final SrsEntityRecord record) => record.id,
        SrsEditEvent(:final SrsFieldEdit edit) => edit.entityId,
        SrsLogEvent(:final SrsReviewLog log) => log.cardId,
        SrsUnknownEvent() => null,
      };
      if (target != null && ids.contains(target)) n++;
    }
    return n;
  }
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

/// [_writes] 里同时写调用方自己实体的入口：它们给自己的实体写操作是本分（日志会变长），对它们只断言「真相里没有指向
/// 别人 ID 的操作」（[_Env.pointingAt]），不断言日志长度不变。
const Set<String> _writesOwnToo = <String>{
  // 自己那条笔记上照常记「与那条不是重复」（实体是自己的笔记，键里带对方的 ID：`notDup/<对方>`），别人的那条不写。
  'dismissDuplicates 自己的 + 别人的',
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
      Uri.parse('http://host/api/srs/remote2/call'),
      body: jsonEncode(<String, Object?>{
        'g': 4,
        'profile': profile,
        'op': op,
        'args': args,
        'request': ?request,
      }),
    ),
    'POST',
    '/api/srs/remote2/call',
  );
  return (
    res.statusCode,
    (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>(),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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
        await a.entityViews(SrsEntityKind.note, ids: <String>[b.note]),
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
        await a.entityViews(SrsEntityKind.noteType, ids: <String>[b.type]),
        isEmpty,
      );
      expect(await a.noteIdsOfType(b.type), isEmpty);
      expect((await a.noteCountsByType())[b.type], isNull);
    });

    test('牌组', () async {
      expect(
        await a.entityViews(SrsEntityKind.deck, ids: <String>[b.deck]),
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
        final List<String> bBefore = await env.dump(kB);
        final int opsBefore = await env.ops(kA);
        final int pointingBefore = await env.pointingAt(kA, env.b.ids);

        final String got = await _outcome(
          () => w.value(a, env.a, _Target.of(env.b)),
        );
        final int opsForeign = await env.ops(kA) - opsBefore;
        // 实体归属闸（BUG-5005）：A 为 B 的 ID 一条都不写。只碰 B 的 ID 的入口按日志长度数（彻底清除之类不留在真相
        // 视图里的也数得到）；同时写 A 自己实体的入口按真相里指向 B 的 ID 的操作数。
        expect(
          await env.pointingAt(kA, env.b.ids) - pointingBefore,
          0,
          reason: 'A 的真相里多了指向 B 的 ID 的操作（$got）',
        );
        if (!_writesOwnToo.contains(w.key)) {
          expect(opsForeign, 0, reason: 'A 为别人的 ID 写了 $opsForeign 条操作（$got）');
        }

        expect(await env.dump(kB), bBefore, reason: 'B 的真相被动了（$got）');
        // B 的 store 读到的也还是原样。
        final SrsNoteView n = (await env.b.store.note(env.b.note))!;
        expect(n.deletedAt, isNull);
        expect(n.field(env.b.expression), '鳥');
        expect(n.tags, <String>['tag-鳥']);
        final SrsCardCacheRow c = (await env.b.store.cardRow(env.b.card))!;
        expect(c.hidden, isFalse);
        expect(c.suspended, isFalse);
        expect(c.lastLogId, env.b.log);
        expect(
          (await env.b.store.noteType(env.b.type))?.name,
          '类型 鳥',
          reason: 'B 专属的笔记类型还在、没被改名（$got）',
        );

        // 对调用方：与「哪里都没有的 ID」同一类结局（正常返回 / 抛同一类错）。不比返回值（返回的是那条悬空记录）。
        // 上面的写入没动 B，这份库接着用。
        String kind(String o) => o.startsWith('ok') ? 'ok' : o;
        final String absent = await _outcome(
          () => w.value(a, env.a, _nowhere(0)),
        );
        expect(kind(got), kind(absent), reason: '别人的 ID：$got；不存在的 ID：$absent');
        expect(await env.dump(kB), bBefore, reason: 'B 的真相被动了（$absent）');
      });
    }

    test('改别人的字段：一条都不落（不存在的 ID 落悬空记录），B 不变', () async {
      final _Env env = await _Env.open();
      final SrsDbStore a = env.a.store;
      final _Side b = env.b;
      final _Target none = _nowhere(1);
      expect(
        (await a.editFields(SrsEntityKind.note, b.note, <String, Object?>{
              SrsFieldKeys.noteField(b.expression): '被改',
            })) ??
            const <SrsFieldEdit>[],
        isEmpty,
      );
      expect(
        (await a.editFields(SrsEntityKind.note, none.note, <String, Object?>{
          SrsFieldKeys.noteField(none.expression): '被改',
        }))?.length,
        1,
      );
      expect((await b.store.note(b.note))!.field(b.expression), '鳥');
      // 一批里自己的照写；不存在的卡落悬空记录，别人的卡被实体归属闸拦下（BUG-5005），B 的卡不变。
      final List<SrsFieldEdit> out = await a.editFieldsBatch(<SrsFieldChange>[
        SrsFieldChange(SrsEntityKind.card, b.card, SrsFieldKeys.flag, 3),
        SrsFieldChange(SrsEntityKind.card, none.card, SrsFieldKeys.flag, 3),
        SrsFieldChange(SrsEntityKind.card, env.a.card, SrsFieldKeys.flag, 3),
      ]);
      final List<String> written = <String>[
        for (final SrsFieldEdit e in out) e.entityId,
      ];
      expect(written, contains(env.a.card));
      expect(written, contains(none.card));
      expect(written, isNot(contains(b.card)));
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
        final List<String> bBefore = await env.dump(kB);
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
        await read('noteTypeViews', <String, Object?>{
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

    test('写：B 的真相逐条不变，A 的结局同给不存在的 ID 时一样、为 B 的 ID 一条都不写', () async {
      final List<String> bBefore = await env.dump(kB);
      int request = 0;
      Map<String, Map<String, Object?>> writesOn(
        _Target b,
      ) => <String, Map<String, Object?>>{
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
      Future<(Map<String, (int, Object?)>, int)> run(_Target t) async {
        final int before = await env.ops(kA);
        final Map<String, (int, Object?)> got = <String, (int, Object?)>{};
        for (final MapEntry<String, Map<String, Object?>> w in writesOn(
          t,
        ).entries) {
          final (int status, Map<String, Object?> body) = await _remote(
            service,
            kA,
            w.key,
            w.value,
            request: 'r${request++}',
          );
          got[w.key] = (status, body['error']);
        }
        return (got, await env.ops(kA) - before);
      }

      final (Map<String, (int, Object?)> got, int foreignOps) = await run(
        _Target.of(b),
      );
      expect(await env.dump(kB), bBefore, reason: '$got');
      final (Map<String, (int, Object?)> absent, int absentOps) = await run(
        _nowhere(2),
      );
      expect(await env.dump(kB), bBefore, reason: '$absent');
      expect(
        <String, int>{
          for (final MapEntry<String, (int, Object?)> e in got.entries)
            e.key: e.value.$1,
        },
        <String, int>{
          for (final MapEntry<String, (int, Object?)> e in absent.entries)
            e.key: e.value.$1,
        },
        reason: '别人的 ID：$got；不存在的 ID：$absent',
      );
      // 这里每个入口只碰 B 的 ID：A 一条都不写（实体归属闸，BUG-5005）；不存在的 ID 照旧落悬空记录。
      expect(foreignOps, 0, reason: '$got / $absent');
      expect(absentOps, greaterThan(0), reason: '$absent');
      // 没有一条回 500（内部错误）：要么照「没有这个实体」正常返回，要么是与不存在同样的 4xx。
      expect(
        got.values.where(((int, Object?) r) => r.$1 >= 500),
        isEmpty,
        reason: '$got',
      );
    });
  });
}
