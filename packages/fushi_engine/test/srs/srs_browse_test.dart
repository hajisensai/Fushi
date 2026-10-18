// 浏览页的领域层：快照 + 搜索 + 排序 + 笔记模式；批量操作一个批次落库、可同步、可撤销。
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

/// 确定性假引擎（同 srs_db_store_test.dart）。
class _FakeEngine implements FsrsEngine {
  const _FakeEngine();

  @override
  String get fsrsRev => 'fake';
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
  SrsMemory _step(SrsMemory? m, int r) => SrsMemory(
    stability: switch (r) {
      1 => 0.3,
      2 => 1.5 + (m?.stability ?? 0),
      3 => 3 + (m?.stability ?? 0) * 2,
      _ => 6 + (m?.stability ?? 0) * 3,
    },
    difficulty: r == 1 ? 9 : 5,
  );
  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r);
      return SrsItemState(memory: m, interval: m.stability);
    }

    return SrsNextStates(again: st(1), hard: st(2), good: st(3), easy: st(4));
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    SrsMemory? m = starting;
    for (final SrsFsrsReview r in reviews) {
      m = _step(m, r.rating);
    }
    return m;
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) => SrsMemory(stability: intervalDays, difficulty: 5);
  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 0.9;
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
    List<int>? cardIds,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}

class _Dir implements SrsSyncDirectory {
  _Dir(this.now);
  final int Function() now;
  final Map<String, Map<String, Uint8List>> files =
      <String, Map<String, Uint8List>>{};
  @override
  Future<List<String>> listWriters() async => files.keys.toList()..sort();
  @override
  Future<List<String>?> listFiles(String w) async => files[w]?.keys.toList();
  @override
  Future<Uint8List?> read(String w, String n) async => files[w]?[n];
  @override
  Future<void> write(String w, String n, Uint8List b) async =>
      (files[w] ??= <String, Uint8List>{})[n] = b;
  @override
  Future<void> delete(String w, String n) async => files[w]?.remove(n);
  @override
  Future<void> deleteWriter(String w) async => files.remove(w);
  @override
  Future<int?> serverTime(String w) async {
    await write(w, srsProbeName, Uint8List(0));
    return now();
  }
}

const String kProfile = '01928c3e-0000-7000-8000-0000000000b7';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
  final List<FushiDatabase> dbs = <FushiDatabase>[];

  setUp(() => t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch);
  tearDown(() async {
    for (final FushiDatabase db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  Future<SrsDbStore> device(String id) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    dbs.add(db);
    return SrsDbStore.open(
      db: db,
      profileUid: kProfile,
      deviceId: id,
      engine: const _FakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  Future<String> add(
    SrsDbStore s,
    String expr, {
    String definition = '',
    List<String> tags = const <String>[],
  }) async {
    final String id = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expr,
        srsLapisFieldId(kProfile, 'MainDefinition'): definition,
      },
      tags: tags,
    );
    t += 1000;
    return id;
  }

  Future<String> cardOf(SrsDbStore s, String noteId) async =>
      (await s.cardsOfNote(noteId)).single.id;

  List<String> exprs(List<SrsBrowseItem> items) => <String>[
    for (final SrsBrowseItem i in items) i.primary.sortText,
  ];

  group('快照：搜索 + 排序', () {
    test('字段限定 / 通配 / 正则 / 标签 / 状态 / prop', () async {
      final SrsDbStore s = await device('a');
      final String a = await add(
        s,
        '食べる',
        definition: 'to eat',
        tags: <String>['n5'],
      );
      await add(s, '飲む', definition: 'to drink', tags: <String>['n5', 'verb']);
      await add(s, '<b>走る</b>', definition: 'to run');
      // 「食べる」复习两次：变成复习卡，有间隔 / 难度 / 复习次数。
      final String ca = await cardOf(s, a);
      await s.answer(ca, 4);
      t += 86400000 * 4;
      await s.answer(ca, 1);

      final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(s);
      List<String> q(String query) => exprs(
        snap.query(
          query: query,
          sort: const SrsBrowseSort(
            column: SrsBrowseSortColumn.created,
            ascending: true,
          ),
        ),
      );
      expect(q(''), <String>['食べる', '飲む', '走る']);
      expect(q('MainDefinition:to*'), <String>['食べる', '飲む', '走る']);
      expect(q('MainDefinition:"to drink"'), <String>['飲む']);
      expect(q('mainDefinition:*r*'), <String>['飲む', '走る']);
      expect(q('Expression:走る'), <String>['走る'], reason: '字段比较先去 HTML');
      expect(q(r'Expression:re:^<b>'), <String>['走る'], reason: 're: 看原文');
      expect(q('tag:n5 -tag:verb'), <String>['食べる']);
      expect(q('is:new'), <String>['飲む', '走る']);
      expect(q('-is:new'), <String>['食べる']);
      expect(q('prop:reps=2 prop:lapses=1'), <String>['食べる']);
      expect(q('prop:d>0.8'), <String>['食べる']);
      expect(q('note:Lapis*'), hasLength(3));
      expect(q('deck:*'), hasLength(3));
      expect(
        () => snap.query(query: 'prop:ease>2'),
        throwsA(isA<SrsSearchUnsupported>()),
      );
      expect(snap.fieldNames, contains('MainDefinition'));
    });

    test('排序：排序字段 / 指定字段 / 到期 / 复习次数 / 修改时间，升降序', () async {
      final SrsDbStore s = await device('a');
      final String a = await add(s, 'b', definition: 'z');
      final String b = await add(s, 'a', definition: 'x');
      await add(s, 'c', definition: 'y');
      await s.answer(await cardOf(s, a), 3);
      await s.answer(await cardOf(s, b), 4);
      t += 1000;
      await s.updateNote(b, tags: <String>['touched']);

      final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(s);
      List<String> sorted(SrsBrowseSort sort) => exprs(snap.query(sort: sort));
      expect(
        sorted(
          const SrsBrowseSort(
            column: SrsBrowseSortColumn.sortField,
            ascending: true,
          ),
        ),
        <String>['a', 'b', 'c'],
      );
      expect(
        sorted(const SrsBrowseSort(column: SrsBrowseSortColumn.sortField)),
        <String>['c', 'b', 'a'],
      );
      expect(
        sorted(
          const SrsBrowseSort(
            column: SrsBrowseSortColumn.field,
            fieldName: 'maindefinition',
            ascending: true,
          ),
        ),
        <String>['a', 'c', 'b'],
      );
      expect(
        sorted(const SrsBrowseSort(column: SrsBrowseSortColumn.created)),
        <String>['c', 'a', 'b'],
      );
      // 到期：复习卡按到期日（a 评「简单」间隔更长 → 更晚），新卡排最后。
      expect(
        sorted(
          const SrsBrowseSort(column: SrsBrowseSortColumn.due, ascending: true),
        ),
        <String>['b', 'a', 'c'],
      );
      // 修改时间：最后改的是 a（标签）。
      expect(
        sorted(const SrsBrowseSort(column: SrsBrowseSortColumn.modified)).first,
        'a',
      );
      // 难度：新卡没有值，升降序都排最后。
      for (final bool asc in <bool>[true, false]) {
        expect(
          sorted(
            SrsBrowseSort(
              column: SrsBrowseSortColumn.difficulty,
              ascending: asc,
            ),
          ).last,
          'c',
        );
      }
      expect(
        sorted(const SrsBrowseSort(column: SrsBrowseSortColumn.reps)).last,
        'c',
      );
    });

    test('笔记模式：一条笔记一行，批量目标是它的全部卡片', () async {
      final SrsDbStore s = await device('a');
      await add(s, '食べる');
      await add(s, '飲む');
      final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(s);
      final List<SrsBrowseItem> notes = snap.query(mode: SrsBrowseMode.notes);
      expect(notes, hasLength(2));
      for (final SrsBrowseItem i in notes) {
        expect(i.cards, isNotEmpty);
        expect(i.cards.every((c) => c.note.id == i.noteId), isTrue);
      }
    });

    test('按字段搜索（不用记语法）：特殊字符转义成字面量', () async {
      final SrsDbStore s = await device('a');
      await add(s, 'a*b_c"d:e');
      await add(s, 'aBBc');
      final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(s);
      expect(srsFieldContainsQuery('Expression', '  '), '');
      expect(
        exprs(
          snap.query(query: srsFieldContainsQuery('Expression', '*b_c"d:')),
        ),
        <String>['a*b_c"d:e'],
      );
      expect(
        exprs(snap.query(query: srsFieldContainsQuery('expression', 'bb'))),
        <String>['aBBc'],
      );
      expect(
        snap.query(query: srsFieldContainsQuery('Expression', 'b_c')),
        hasLength(1),
        reason: '_ 是字面量，不是单字符通配',
      );
    });

    test('删除的笔记不出现', () async {
      final SrsDbStore s = await device('a');
      final String a = await add(s, '食べる');
      await add(s, '飲む');
      await s.deleteNote(a);
      expect(exprs((await SrsBrowseSnapshot.load(s)).query()), <String>['飲む']);
    });
  });

  group('批量操作', () {
    test('暂停：一个批次、只写真改动的卡；撤销写回原值；同步到另一台设备', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final List<String> cards = <String>[
        for (final String e in <String>['一', '二', '三'])
          await cardOf(a, await add(a, e)),
      ];
      await a.setSuspended(cards[0], true);
      final int before = (await a.unpublishedEvents()).length;
      final SrsBatchOutcome out = await srsBatchSetSuspended(
        a,
        cards,
        suspended: true,
      );
      expect(out.changed, 2, reason: '已暂停的那张不再写');
      expect((await a.unpublishedEvents()).length, before + 2);
      for (final SrsCardCacheRow r in await a.cardRows(cards)) {
        expect(r.suspended, isTrue);
      }

      final _Dir dir = _Dir(() => t);
      for (int i = 0; i < 3; i++) {
        await SrsSyncEngine(directory: dir, replica: a).syncOnce();
        await SrsSyncEngine(directory: dir, replica: b).syncOnce();
      }
      for (final SrsCardCacheRow r in await b.cardRows(cards)) {
        expect(r.suspended, isTrue, reason: '批量写的是普通修改记录，照常同步');
      }

      t += 1000;
      expect(await out.revert!(a), 0);
      final Map<String, bool> after = <String, bool>{
        for (final SrsCardCacheRow r in await a.cardRows(cards))
          r.id: r.suspended,
      };
      expect(after[cards[0]], isTrue, reason: '本来就暂停的保持暂停');
      expect(after[cards[1]], isFalse);
      expect(after[cards[2]], isFalse);
    });

    test('搁置 / 旗标 / 改牌组', () async {
      final SrsDbStore s = await device('a');
      final List<String> cards = <String>[
        await cardOf(s, await add(s, '一')),
        await cardOf(s, await add(s, '二')),
      ];
      final SrsBatchOutcome bury = await srsBatchSetBuried(
        s,
        cards,
        buried: true,
      );
      expect(bury.changed, 2);
      final SrsBrowseSnapshot snap = await SrsBrowseSnapshot.load(s);
      expect(snap.query(query: 'is:buried'), hasLength(2));
      await bury.revert!(s);
      expect(
        (await SrsBrowseSnapshot.load(s)).query(query: 'is:buried'),
        isEmpty,
      );

      final SrsBatchOutcome flag = await srsBatchSetFlag(s, cards, 4);
      expect(flag.changed, 2);
      expect(
        (await SrsBrowseSnapshot.load(s)).query(query: 'flag:4'),
        hasLength(2),
      );
      await flag.revert!(s);
      expect(
        (await SrsBrowseSnapshot.load(s)).query(query: 'flag:0'),
        hasLength(2),
      );

      final String deck = await s.createDeck('Other');
      final SrsBatchOutcome move = await srsBatchMoveCards(s, cards, deck);
      expect(move.changed, 2);
      expect(
        (await SrsBrowseSnapshot.load(s)).query(query: 'deck:Other'),
        hasLength(2),
      );
      await move.revert!(s);
      expect(
        (await SrsBrowseSnapshot.load(s)).query(query: 'deck:Other'),
        isEmpty,
      );
    });

    test('加 / 删标签（不区分大小写、去重），撤销', () async {
      final SrsDbStore s = await device('a');
      final String n1 = await add(s, '一', tags: <String>['old', 'N5']);
      final String n2 = await add(s, '二');
      expect(srsParseTags('  a  b A c '), <String>['a', 'b', 'c']);
      final SrsBatchOutcome addOut = await srsBatchEditTags(
        s,
        <String>[n1, n2],
        add: <String>['n5', 'new'],
      );
      expect(addOut.changed, 2);
      expect((await s.note(n1))!.tags, <String>['old', 'N5', 'new']);
      expect((await s.note(n2))!.tags, <String>['n5', 'new']);
      final SrsBatchOutcome rm = await srsBatchEditTags(
        s,
        <String>[n1, n2],
        remove: <String>['OLD'],
      );
      expect(rm.changed, 1);
      expect((await s.note(n1))!.tags, <String>['N5', 'new']);
      await rm.revert!(s);
      await addOut.revert!(s);
      expect((await s.note(n1))!.tags, <String>['old', 'N5']);
      expect((await s.note(n2))!.tags, isEmpty);
    });

    test('删除笔记 → 撤销恢复', () async {
      final SrsDbStore s = await device('a');
      final String n1 = await add(s, '一');
      final String n2 = await add(s, '二');
      final SrsBatchOutcome del = await srsBatchDeleteNotes(s, <String>[
        n1,
        n2,
      ]);
      expect(del.changed, 2);
      expect((await SrsBrowseSnapshot.load(s)).cards, isEmpty);
      t += 1000;
      await del.revert!(s);
      expect((await SrsBrowseSnapshot.load(s)).cards, hasLength(2));
    });

    test('重置为新卡 / 设置到期日：一批日志，撤销 = 撤那批日志；已被后续复习覆盖的撤不掉', () async {
      final SrsDbStore s = await device('a');
      final String c1 = await cardOf(s, await add(s, '一'));
      final String c2 = await cardOf(s, await add(s, '二'));
      final String c3 = await cardOf(s, await add(s, '三'));
      await s.answer(c1, 4);
      await s.answer(c2, 4);

      final SrsBatchOutcome reset = await srsBatchResetCards(s, <String>[
        c1,
        c2,
        c3,
      ]);
      expect(reset.changed, 2, reason: '本来就是新卡的不写');
      for (final SrsCardCacheRow r in await s.cardRows(<String>[c1, c2])) {
        expect(r.queue, SrsQueue.newCard.wire);
      }
      // c2 重置后又复习了一次：那条重置日志已不是最后一条有效日志，撤不掉。
      t += 1000;
      await s.answer(c2, 4);
      expect(await reset.revert!(s), 1);
      expect((await s.cardRow(c1))!.queue, SrsQueue.review.wire);

      expect(srsParseDueDays('3'), (3, 3));
      expect(srsParseDueDays(' 7 - 2 '), (2, 7));
      expect(srsParseDueDays('x'), isNull);
      final SrsDayContext day = await s.dayContext();
      final int today = day.dayIndexOf(t);
      final SrsBatchOutcome due = await srsBatchSetDue(
        s,
        <String>[c1, c3],
        from: 5,
        to: 10,
        random: Random(1),
      );
      expect(due.changed, 2);
      for (final SrsCardCacheRow r in await s.cardRows(<String>[c1, c3])) {
        expect(r.queue, SrsQueue.review.wire);
        expect(r.dueDay, inInclusiveRange(today + 5, today + 10));
      }
      expect(await due.revert!(s), 0);
      expect((await s.cardRow(c3))!.queue, SrsQueue.newCard.wire);
    });
  });
}
