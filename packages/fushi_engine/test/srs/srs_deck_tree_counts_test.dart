// BUG-3502：牌组树计数自底向上（Anki v3 limit tree），列表数字与复习页实际出卡一致；
// 以及牌组折叠（collapsed）的存储、合并与排序。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

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

    test('学习中的卡不受上限截断，逐层求和', () async {
      await limits(s, a, 0);
      // 学习中：Again 留在学习队列。
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
}
