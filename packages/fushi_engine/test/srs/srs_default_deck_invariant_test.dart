// 默认牌组不变式（BUG-5209）：牌组树里恒有内核规范 ID 的默认牌组。「有效牌组」与排程配置都回落到它，浏览页给
// 「牌组已不存在」的兜底项取排程配置（`srsBrowseContext.recall('\u0000')` → `schedulingConfig(defaultDeckId)`），
// 树里缺它就空断言、整页加载失败。
//
// - 内核 `deck_delete`：默认牌组被挪进要删的子树时不随之删除，挂回顶层，它的卡不动。
// - 开库（`ensureBuiltins`）：旧版留下的、带删除标记的默认牌组复活并挂回顶层，浏览页照常加载。
@TestOn('vm')
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';

const String _uid = '01928c3e-0000-7000-8000-0000000052a9';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 11, 22, 3).millisecondsSinceEpoch;

  Future<SrsDbStore> open(SrsStorage storage) => openTestStore(
    profileUid: _uid,
    deviceId: 'a',
    now: () => t += 1000,
    storage: storage,
  );

  Future<String> note(SrsDbStore s, String word, {String? deckId}) =>
      s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{srsLapisFieldId(_uid, 'Expression'): word},
        deckId: deckId,
      );

  Future<void> expectBrowseLoads(SrsDbStore s, String noteId) async {
    // 浏览页那条兜底：不存在的牌组回落到默认牌组取排程配置。
    expect(s.schedulingConfigFor('\u0000'), completes);
    final List<SrsBrowseRow> rows = await (await SrsBrowseSession(
      s,
    ).query()).all();
    final List<SrsBrowseRow> mine = <SrsBrowseRow>[
      for (final SrsBrowseRow r in rows)
        if (r.noteId == noteId) r,
    ];
    expect(mine, isNotEmpty);
    for (final SrsBrowseRow r in mine) {
      expect(r.deckId, s.defaultDeckId);
    }
  }

  test('删除含默认牌组的父牌组：默认牌组留下、挂回顶层，卡不动', () async {
    final SrsDbStore s = await open(await openTestSrsStorage());
    final String lang = await s.createDeck('Lang');
    final String inDefault = await note(s, '一');
    await note(s, '二', deckId: lang);
    expect(await s.moveDeck(s.defaultDeckId, lang), SrsDeckMoveResult.moved);
    expect((await s.deckTree()).parentOf(s.defaultDeckId), lang);

    await s.deleteDeck(lang, deleteCards: true);

    final SrsDeckTree tree = await s.deckTree();
    expect(tree[lang], isNull);
    expect(tree[s.defaultDeckId], isNotNull, reason: '默认牌组不随父牌组删除');
    expect(tree.parentOf(s.defaultDeckId), isNull, reason: '挂回顶层');
    for (final SrsCardCacheRow c in await s.cardsOfNote(inDefault)) {
      expect(c.deckId, s.defaultDeckId);
    }
    await expectBrowseLoads(s, inDefault);
  });

  test('旧版留下的带删除标记的默认牌组：开库时复活，浏览页照常加载', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await open(storage);
    final String lang = await s.createDeck('Lang');
    final String inDefault = await note(s, '一');
    // 旧版删 Lang 时把挪进它子树的默认牌组连带写了删除标记（内核已不这样做，这里直接写出那份状态）。
    await s.editField(
      SrsEntityKind.deck,
      s.defaultDeckId,
      SrsFieldKeys.deckParent,
      lang,
    );
    await s.editField(SrsEntityKind.deck, lang, SrsFieldKeys.deleted, t);
    await s.editField(
      SrsEntityKind.deck,
      s.defaultDeckId,
      SrsFieldKeys.deleted,
      t,
    );
    expect((await s.deckTree())[s.defaultDeckId], isNull);
    // 修复之前：浏览页的兜底项在这里空断言（反馈 -U8Zeewe6f 的栈）。
    await expectLater(s.schedulingConfigFor('\u0000'), throwsA(anything));

    final SrsDbStore reopened = await open(storage);
    final SrsDeckTree tree = await reopened.deckTree();
    expect(tree[reopened.defaultDeckId], isNotNull, reason: '开库复活默认牌组');
    expect(tree.parentOf(reopened.defaultDeckId), isNull);
    expect(tree[lang], isNull, reason: '别的已删除牌组不动');
    await expectBrowseLoads(reopened, inDefault);

    // 修好之后再开一次不再写：已经是活的。
    final int before = (await reopened.deckTree()).decks.length;
    final SrsDbStore again = await open(storage);
    expect((await again.deckTree()).decks.length, before);
  });
}
