// BUG-3502：牌组树计数自底向上（Anki v3 limit tree），列表数字与复习页实际出卡一致；
// 以及牌组折叠（collapsed）的存储、合并与排序。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';

const String kTreeProfile = '01928c3e-0000-7000-8000-0000000000aa';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
  });

  Future<SrsDbStore> open([String device = 'a']) =>
      openTestStore(profileUid: kTreeProfile, deviceId: device, now: () => t);

  int seq = 0;
  Future<List<String>> addNew(SrsDbStore s, String deckId, int n) async {
    final List<String> out = <String>[];
    for (int i = 0; i < n; i++) {
      final String noteId = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kTreeProfile, 'Expression'): 'w${seq++}',
        },
        deckId: deckId,
      );
      out.add((await s.cardsOfNote(noteId)).single.id);
    }
    return out;
  }

  Future<void> limits(SrsDbStore s, String deckId, int newPerDay) =>
      s.editField(
        SrsEntityKind.deck,
        deckId,
        SrsFieldKeys.deckLimits,
        <String, Object?>{'new': newPerDay, 'review': 200},
      );

  Future<Map<String, SrsDeckSummary>> summaries(SrsDbStore s) async =>
      <String, SrsDeckSummary>{
        for (final SrsDeckSummary d in await s.deckSummaries()) d.fullName: d,
      };

  /// 从 [deckId] 开始复习，把能出的新卡全部学掉（Easy 直接进复习队列），返回每张卡所在牌组。
  Future<List<String>> drainNew(SrsDbStore s, String deckId) async {
    final List<String> decksOfPicked = <String>[];
    for (int guard = 0; guard < 500; guard++) {
      final String? id = await s.nextCard(deckId);
      if (id == null) break;
      final SrsCardCacheRow row = (await s.cardRow(id))!;
      if (row.queue != SrsQueue.newCard.wire) break;
      decksOfPicked.add(row.deckId);
      await s.answer(id, 4);
    }
    return decksOfPicked;
  }

  group('BUG-3502 牌组树计数', () {
    late SrsDbStore s;
    late String root, a, a1, a2, b, b1;

    setUp(() async {
      s = await open();
      root = await s.ensureDeckPath('Root');
      a = await s.ensureDeckPath('Root::A');
      a1 = await s.ensureDeckPath('Root::A::A1');
      a2 = await s.ensureDeckPath('Root::A::A2');
      b = await s.ensureDeckPath('Root::B');
      b1 = await s.ensureDeckPath('Root::B::B1');
      await limits(s, root, 10);
      await limits(s, a, 3);
      await limits(s, a1, 50);
      await limits(s, a2, 50);
      await limits(s, b, 20);
      await limits(s, b1, 20);
      await addNew(s, root, 1);
      await addNew(s, a1, 5);
      await addNew(s, a2, 5);
      await addNew(s, b, 2);
      await addNew(s, b1, 4);
    });

    test('自底向上：父 = min(自己剩余上限, 自己的卡 + Σ 子牌组截断后的数)', () async {
      final Map<String, SrsDeckSummary> m = await summaries(s);
      expect(m['Root::A::A1']!.newCount, 5);
      expect(m['Root::A::A2']!.newCount, 5);
      // A 的上限 3 截断了两个子牌组的 10 张。
      expect(m['Root::A']!.newCount, 3);
      expect(m['Root::B::B1']!.newCount, 4);
      expect(m['Root::B']!.newCount, 6);
      // 旧实现：min(10, 子树原始 17) = 10，与 1 + 3 + 6 = 10 恰好相同；把上限放宽看差别。
      expect(m['Root']!.newCount, 10);
      await limits(s, root, 100);
      final Map<String, SrsDeckSummary> m2 = await summaries(s);
      // 旧实现会显示 17（子树原始新卡数），子牌组的上限没往上截断。
      expect(m2['Root']!.newCount, 1 + 3 + 6);
    });

    test('子牌组全 0 时父牌组不会凭自己的上限显示新卡（用户报告的形态）', () async {
      await limits(s, a, 0);
      await limits(s, b, 0);
      final Map<String, SrsDeckSummary> m = await summaries(s);
      expect(m['Root::A::A1']!.newCount, 5, reason: '子牌组只受自己的上限');
      expect(m['Root::A']!.newCount, 0);
      expect(m['Root::B']!.newCount, 0);
      // 只剩 Root 自己的 1 张。
      expect(m['Root']!.newCount, 1);
      final List<String> picked = await drainNew(s, root);
      expect(picked, <String>[root]);
    });

    test('已学部分配额：今天学过的新卡记在卡所在牌组及其全部祖先上', () async {
      // 从 A1 学 2 张（点子牌组时祖先的上限不参与，A 的 3 不挡）。
      for (int i = 0; i < 2; i++) {
        final String id = (await s.nextCard(a1))!;
        expect((await s.cardRow(id))!.deckId, a1);
        await s.answer(id, 4);
      }
      final Map<String, SrsDeckSummary> m = await summaries(s);
      expect(m['Root::A::A1']!.newCount, 3);
      expect(m['Root::A::A2']!.newCount, 5);
      expect(m['Root::A']!.newCount, 1, reason: 'A 上限 3 − 子树已学 2');
      expect(m['Root']!.newCount, 8, reason: 'min(10 − 2, 1 + 1 + 6)');
    });

    test('点父牌组复习：实际出的新卡数 = 列表显示数，且各层上限都守住', () async {
      final Map<String, SrsDeckSummary> before = await summaries(s);
      final List<String> picked = await drainNew(s, root);
      expect(picked, hasLength(before['Root']!.newCount));
      final int fromA = picked
          .where((String d) => d == a || d == a1 || d == a2)
          .length;
      expect(fromA, lessThanOrEqualTo(3));
      final Map<String, SrsDeckSummary> after = await summaries(s);
      expect(after['Root']!.newCount, 0);
      expect(after['Root::A']!.newCount, 0);
    });

    test('点子牌组复习：出卡数 = 子牌组行显示数', () async {
      final Map<String, SrsDeckSummary> before = await summaries(s);
      final List<String> picked = await drainNew(s, a);
      expect(picked, hasLength(before['Root::A']!.newCount));
      expect(picked.every((String d) => d == a1 || d == a2), isTrue);
    });

    test('BUG-3579：单牌组计数（复习页用）与列表里同一牌组那一行逐项相同', () async {
      // 今天学过 / 留在学习队列的卡都要算进去（newDone 与 learn 走的是另一条查询）。
      for (int i = 0; i < 2; i++) {
        await s.answer((await s.nextCard(a1))!, 4);
      }
      await s.answer((await s.nextCard(b1))!, 1);
      String key(SrsDeckSummary d) =>
          '${d.fullName} ${d.newCount}/${d.learnCount}/${d.reviewCount}/'
          '${d.totalCards}/${d.newBudget.allowed}';
      for (final SrsDeckSummary row in await s.deckSummaries()) {
        expect(key((await s.deckSummary(row.deck.id))!), key(row));
      }
    });

    test('学习中的卡不受上限截断，逐层求和', () async {
      await limits(s, a, 0);
      // 学习中：Again 留在学习队列（RWKV 牌组缺省不用步长，这里写上步长）。
      await s.editFields(SrsEntityKind.deck, a1, <String, Object?>{
        SrsFieldKeys.deckSteps: <String, Object?>{
          'learn': <double>[1, 10],
          'relearn': <double>[10],
        },
      });
      final String id = (await s.nextCard(a1))!;
      await s.answer(id, 1);
      final Map<String, SrsDeckSummary> m = await summaries(s);
      expect(m['Root::A::A1']!.learnCount, 1);
      expect(m['Root::A']!.learnCount, 1);
      expect(m['Root']!.learnCount, 1);
    });
  });

  group('牌组折叠', () {
    test('缺省展开；setDeckCollapsed 写进牌组，重复写同值不产生记录', () async {
      final SrsDbStore s = await open();
      final String p = await s.ensureDeckPath('P::C');
      final String parent = (await s.deckTree()).parentOf(p)!;
      expect((await s.deckTree())[parent]!.collapsed, isFalse);
      await s.setDeckCollapsed(parent, true);
      expect((await s.deckTree())[parent]!.collapsed, isTrue);
      final SrsFieldEdit? again = await s.editField(
        SrsEntityKind.deck,
        parent,
        SrsFieldKeys.deckCollapsed,
        true,
      );
      expect(again, isNull);
      await s.setDeckCollapsed(parent, false);
      expect((await s.deckTree())[parent]!.collapsed, isFalse);
    });

    test('折叠是界面状态：并发开合按最后修改生效，不进同步冲突记录', () {
      expect(
        srsFieldClassOf(SrsEntityKind.deck, SrsFieldKeys.deckCollapsed),
        SrsFieldClass.viewState,
      );
      expect(
        srsFieldClassOf(SrsEntityKind.deck, SrsFieldKeys.deckLimits),
        SrsFieldClass.setting,
      );
    });

    test('牌组列表先序：子牌组紧跟父牌组（Lang2 不插进 Lang 与 Lang::JP 之间）', () async {
      final SrsDbStore s = await open();
      await s.ensureDeckPath('Lang::JP');
      await s.ensureDeckPath('Lang2');
      final List<String> names = <String>[
        for (final SrsDeckSummary d in await s.deckSummaries()) d.fullName,
      ];
      expect(
        names.indexOf('Lang::JP'),
        names.indexOf('Lang') + 1,
        reason: '$names',
      );
      final SrsDeckSummary jp = (await s.deckSummaries()).firstWhere(
        (SrsDeckSummary d) => d.fullName == 'Lang::JP',
      );
      expect(jp.parentId, (await s.deckTree()).parentOf(jp.deck.id));
      expect(jp.parentId, isNotNull);
    });
  });

  group('moveDeck（拖放牌组）', () {
    test('挪到别的牌组下 / 挪回顶层：子树、卡与 ID 跟着走，全名随之变', () async {
      final SrsDbStore s = await open();
      final String jp = await s.ensureDeckPath('Lang::JP');
      final String kanji = await s.ensureDeckPath('Lang::JP::Kanji');
      final String other = await s.createDeck('Other');
      final List<String> cards = await addNew(s, kanji, 2);

      expect(await s.moveDeck(jp, other), SrsDeckMoveResult.moved);
      Map<String, SrsDeckSummary> byName = await summaries(s);
      expect(byName['Other::JP']!.deck.id, jp);
      expect(byName['Other::JP::Kanji']!.deck.id, kanji);
      expect(byName.containsKey('Lang::JP'), isFalse);
      for (final String c in cards) {
        expect((await s.cardRow(c))!.deckId, kanji);
      }

      expect(await s.moveDeck(jp, null), SrsDeckMoveResult.moved);
      byName = await summaries(s);
      expect(byName['JP']!.deck.id, jp);
      expect(byName['JP::Kanji']!.deck.id, kanji);
      expect(byName['JP']!.parentId, isNull);
    });

    test('挪走后按旧全名再建：得到新牌组，挪走的那个父牌组不变', () async {
      final SrsDbStore s = await open();
      final String jp = await s.ensureDeckPath('Lang::JP');
      final String other = await s.createDeck('Other');
      final List<String> cards = await addNew(s, jp, 1);
      expect(await s.moveDeck(jp, other), SrsDeckMoveResult.moved);

      final String again = await s.ensureDeckPath('Lang::JP');
      expect(again, isNot(jp));
      final SrsDeckTree tree = await s.deckTree();
      expect(tree.fullName(jp), 'Other::JP');
      expect(tree.parentOf(jp), other);
      expect(tree.fullName(again), 'Lang::JP');
      expect((await s.cardRow(cards.single))!.deckId, jp);
      // 再按旧全名找：找到的是新建的那个，不再派生新的。
      expect(await s.ensureDeckPath('Lang::JP'), again);
      expect(await s.createDeck('JP', parentId: tree.parentOf(again)), again);
    });

    test('改名后按旧名再建：得到新牌组，改过名的那个名字不变', () async {
      final SrsDbStore s = await open();
      final String a = await s.createDeck('A');
      await s.editField(SrsEntityKind.deck, a, SrsFieldKeys.name, 'B');
      final String again = await s.createDeck('A');
      expect(again, isNot(a));
      final SrsDeckTree tree = await s.deckTree();
      expect(tree.fullName(a), 'B');
      expect(tree.fullName(again), 'A');
    });

    test('删掉后在原处按原名再建：仍复活沿用原 ID', () async {
      final SrsDbStore s = await open();
      final String a = await s.createDeck('A');
      await s.deleteDeck(a);
      expect((await s.deckTree())[a], isNull);
      expect(await s.createDeck('A'), a);
      expect((await s.deckTree()).fullName(a), 'A');
    });

    test('多设备：收下挪动记录的设备按旧全名新建，与挪动方得到同一个 ID', () async {
      final SrsMemoryLocationStore dir = SrsMemoryLocationStore();
      final SrsDbStore a = await open('a');
      final SrsDbStore b = await open('b');
      Future<void> syncAll() async {
        for (int round = 0; round < 3; round++) {
          for (final SrsDbStore s in <SrsDbStore>[a, b]) {
            await srsSyncOnce(s, dir);
          }
        }
      }

      final String jp = await a.ensureDeckPath('Lang::JP');
      final String other = await a.createDeck('Other');
      await syncAll();
      expect(await a.moveDeck(jp, other), SrsDeckMoveResult.moved);
      await syncAll();
      expect((await b.deckTree()).fullName(jp), 'Other::JP');

      // 两边离线各按旧全名新建。
      final String onA = await a.ensureDeckPath('Lang::JP');
      final String onB = await b.ensureDeckPath('Lang::JP');
      expect(onA, onB);
      expect(onA, isNot(jp));
      await syncAll();
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        final SrsDeckTree tree = await s.deckTree();
        expect(tree.fullName(jp), 'Other::JP');
        expect(tree.fullName(onA), 'Lang::JP');
        expect(await s.syncConflicts(), isEmpty);
      }
    });

    test('拒绝：挪进自己 / 子孙、目标下有同名、原地不动；都不写库', () async {
      final SrsDbStore s = await open();
      final String jp = await s.ensureDeckPath('Lang::JP');
      final String lang = (await s.deckTree()).parentOf(jp)!;
      final String kanji = await s.ensureDeckPath('Lang::JP::Kanji');
      await s.ensureDeckPath('Other::JP');
      final String other = (await s.deckTree()).parentOf(
        (await summaries(s))['Other::JP']!.deck.id,
      )!;
      final List<String> before = (await summaries(s)).keys.toList()..sort();

      expect(await s.moveDeck(lang, kanji), SrsDeckMoveResult.intoOwnSubtree);
      expect(await s.moveDeck(lang, lang), SrsDeckMoveResult.intoOwnSubtree);
      expect(await s.moveDeck(jp, other), SrsDeckMoveResult.nameTaken);
      expect(await s.moveDeck(jp, lang), SrsDeckMoveResult.unchanged);
      expect(await s.moveDeck(jp, 'no-such-deck'), SrsDeckMoveResult.missing);
      expect((await summaries(s)).keys.toList()..sort(), before);
    });

    Future<List<String>> order(SrsDbStore s) async => <String>[
      for (final SrsDeckSummary d in await s.deckSummaries())
        if (d.deck.name != 'Default') d.fullName,
    ];

    test('同级手动排序：插到指定牌组前 / 末尾；子树跟着父牌组走；没排过时仍按名字', () async {
      final SrsDbStore s = await open();
      final String a = await s.createDeck('A');
      final String b = await s.createDeck('B');
      final String c = await s.createDeck('C');
      await s.ensureDeckPath('B::x');
      expect(await order(s), <String>['A', 'B', 'B::x', 'C']);

      expect(
        await s.placeDeck(c, parentId: null, beforeId: a),
        SrsDeckMoveResult.moved,
      );
      expect(await order(s), <String>['C', 'A', 'B', 'B::x']);

      // 同父下挪到末尾（下移到底 / 拖到最后一个后面）也要真写位置。
      expect(await s.placeDeck(c, parentId: null), SrsDeckMoveResult.moved);
      expect(await order(s), <String>['A', 'B', 'B::x', 'C']);

      expect(
        await s.placeDeck(b, parentId: null, beforeId: a),
        SrsDeckMoveResult.moved,
      );
      expect(await order(s), <String>['B', 'B::x', 'A', 'C']);

      // 原地不动：不写库。
      expect(
        await s.placeDeck(b, parentId: null, beforeId: a),
        SrsDeckMoveResult.unchanged,
      );
      // beforeId 不是目标下的同级：拒绝。
      expect(
        await s.placeDeck(a, parentId: null, beforeId: 'nope'),
        SrsDeckMoveResult.missing,
      );
    });

    test('位置是界面状态：并发排序按最后修改生效，不进冲突记录；新建牌组排在手动排过的之后', () async {
      expect(
        srsFieldClassOf(SrsEntityKind.deck, SrsFieldKeys.deckPosition),
        SrsFieldClass.viewState,
      );
      final SrsDbStore s = await open();
      final String a = await s.createDeck('A');
      await s.createDeck('B');
      await s.placeDeck(a, parentId: null);
      await s.createDeck('0-new');
      expect(await order(s), <String>['B', 'A', '0-new']);
    });

    test('挪进别的父牌组且没指定位置：新同级都没排过时保持按名字，不给整组写位置', () async {
      final SrsDbStore s = await open();
      final String p = await s.createDeck('P');
      await s.ensureDeckPath('P::b');
      await s.ensureDeckPath('P::d');
      final String c = await s.createDeck('c');
      expect(await s.moveDeck(c, p), SrsDeckMoveResult.moved);
      expect(await order(s), <String>['P', 'P::b', 'P::c', 'P::d']);
      for (final SrsDeckSummary d in await s.deckSummaries()) {
        expect(d.deck.position, isNull, reason: d.fullName);
      }
    });
  });
}
