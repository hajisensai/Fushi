// 新卡按词频出卡（牌组「新卡顺序」，srs_cards_cache.freq_rank，srs.db v8）：名次从笔记的词频序字段派生、
// 随笔记刷新；按词频的牌组名次在前，按位置的牌组退回位置序。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';

const String kFreqProfile = '01928c3e-0000-7000-8000-0000000000c1';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;
  });

  Future<SrsDbStore> open() =>
      openTestStore(profileUid: kFreqProfile, deviceId: 'a', now: () => t);

  String lapis(String field) => srsLapisFieldId(kFreqProfile, field);

  /// 依次建 Lapis 笔记（创建时刻逐个递增），[ranks] 是 FreqSort 的原始值；返回各自唯一那张卡的 id。
  Future<List<String>> addLapis(
    SrsDbStore s,
    List<(String, String)> wordsAndRanks,
  ) async {
    final List<String> out = <String>[];
    for (final (String w, String rank) in wordsAndRanks) {
      t += 1000;
      final String noteId = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          lapis('Expression'): w,
          lapis('FreqSort'): rank,
        },
      );
      out.add((await s.cardsOfNote(noteId)).single.id);
    }
    return out;
  }

  Future<List<String>> drain(SrsDbStore s) async {
    final List<String> order = <String>[];
    for (int guard = 0; guard < 50; guard++) {
      final String? id = await s.nextCard(s.defaultDeckId);
      if (id == null) break;
      order.add(id);
      await s.answer(id, 4);
    }
    return order;
  }

  // 名次解析（去 HTML 取第一段数字，非正整数 = 没有名次）搬进了 Rust 缓存计算：固定向量回归在
  // native/fushi_fsrs/src/card_cache.rs `freq_rank_dart_vectors`。

  test('缺省按词频：有名次的按名次升序先出，没有名次的在后、按添加先后；不写任何位置', () async {
    final SrsDbStore s = await open();
    final List<String> c = await addLapis(s, <(String, String)>[
      ('雪', '300'),
      ('空', ''),
      ('上手', '100'),
      ('海', ''),
      ('犬', '200'),
    ]);
    expect((await s.cardRow(c[0]))!.freqRank, 300);
    expect((await s.cardRow(c[1]))!.freqRank, isNull);
    expect(await drain(s), <String>[c[2], c[4], c[0], c[1], c[3]]);
    for (final String id in c) {
      expect((await s.cardRow(id))!.newPosition, isNull);
    }
  });

  test('按词频时位置不压过名次；改成按位置则回到位置序', () async {
    final SrsDbStore s = await open();
    final List<String> c = await addLapis(s, <(String, String)>[
      ('雪', '300'),
      ('上手', '100'),
    ]);
    await s.setNewCardPositions(<String, int>{c[0]: 1, c[1]: 2});
    expect(await s.nextCard(s.defaultDeckId), c[1]);
    await s.editFields(SrsEntityKind.deck, s.defaultDeckId, <String, Object?>{
      SrsFieldKeys.deckNewOrder: SrsNewCardOrder.position.wire,
    });
    expect(
      (await s.deckTree())[s.defaultDeckId]!.newCardOrder,
      SrsNewCardOrder.position,
    );
    expect(await s.nextCard(s.defaultDeckId), c[0]);
  });

  test('改笔记的 FreqSort：名次随笔记刷新', () async {
    final SrsDbStore s = await open();
    final List<String> c = await addLapis(s, <(String, String)>[
      ('雪', '300'),
      ('上手', '100'),
    ]);
    final String snowNote = (await s.cardRow(c[0]))!.noteId;
    await s.updateNote(
      snowNote,
      fieldsById: <String, String>{lapis('FreqSort'): '5'},
    );
    expect((await s.cardRow(c[0]))!.freqRank, 5);
    expect(await s.nextCard(s.defaultDeckId), c[0]);
  });

  test('内置 Lapis 改了字段名仍认（内置默认按字段 id）；自建类型按名字 FreqSort 认，可显式改选', () async {
    final SrsDbStore s = await open();
    await s.renameField(s.lapisNoteTypeId, lapis('FreqSort'), '频率');
    final SrsNoteTypeView lapisType = (await s.noteType(s.lapisNoteTypeId))!;
    expect(lapisType.freqFieldId, lapis('FreqSort'));
    expect(lapisType.effectiveFreqFieldId, lapis('FreqSort'));
    final List<String> lapisCards = await addLapis(s, <(String, String)>[
      ('雪', '<b>42</b> (JPDB)'),
    ]);
    expect((await s.cardRow(lapisCards.single))!.freqRank, 42);

    final String typeId = await s.createStockNoteType(
      SrsStockNoteType.basic,
      'Custom',
    );
    final String freqSort = await s.addField(typeId, 'freqsort');
    final String other = await s.addField(typeId, 'Rank');
    SrsNoteTypeView custom = (await s.noteType(typeId))!;
    expect(custom.freqFieldId, isNull);
    expect(
      custom.effectiveFreqFieldId,
      freqSort,
      reason: '没显式设：按名字 FreqSort 认',
    );

    t += 1000;
    final String noteId = await s.createNote(
      noteTypeId: typeId,
      fieldsById: <String, String>{
        custom.fields.first.id: 'x',
        freqSort: '50',
        other: '9',
      },
    );
    final String card = (await s.cardsOfNote(noteId)).single.id;
    expect((await s.cardRow(card))!.freqRank, 50);

    // 显式改选：同类型笔记的缓存跟着重算。
    await s.setFreqField(typeId, other);
    custom = (await s.noteType(typeId))!;
    expect(custom.freqFieldId, other);
    expect(custom.effectiveFreqFieldId, other);
    expect((await s.cardRow(card))!.freqRank, 9);

    // 清掉显式设置：回到按名字认。
    await s.setFreqField(typeId, null);
    expect((await s.cardRow(card))!.freqRank, 50);
  });

  test('老库（缓存修订号 5、freq_rank 为空）打开时补齐名次', () async {
    final SrsStorage st = await openTestSrsStorage();
    Future<SrsDbStore> openOn() => SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kFreqProfile,
      deviceId: 'dev',
    );
    final SrsDbStore s = await openOn();
    final List<String> c = await addLapis(s, <(String, String)>[
      ('雪', '300'),
      ('上手', '100'),
    ]);
    await st.db.customStatement('UPDATE srs_cards_cache SET freq_rank = NULL');
    await st.db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 5)",
    );

    final SrsDbStore reopened = await openOn();
    expect((await reopened.cardRow(c[0]))!.freqRank, 300);
    expect((await reopened.cardRow(c[1]))!.freqRank, 100);
    expect(await reopened.nextCard(reopened.defaultDeckId), c[1]);
  });

  test('字段类别：词频序字段与词条字段同为设置类（最后修改生效、不按内容冲突）', () {
    expect(
      srsFieldClassOf(SrsEntityKind.noteType, SrsFieldKeys.freqField),
      SrsFieldClass.setting,
    );
    expect(
      srsFieldClassOf(SrsEntityKind.noteType, SrsFieldKeys.termField),
      SrsFieldClass.setting,
    );
  });
}
