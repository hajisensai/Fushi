import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'srs_test_support.dart';

/// 编辑页的牌组选择只要 id + 全名：[srsDeckChoices] 只读牌组树，不跑计数 / RWKV 即时
/// 推理（`deckSummaries` 那一套），但顺序与名字必须与 `deckSummaries` 逐项一致——
/// 否则换成轻量版后选择器里的牌组顺序 / 全名会和牌组列表对不上。
void main() {
  test('srsDeckChoices 与 deckSummaries 的 id / 全名 / 顺序逐项一致', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);

    final String lang = await store.createDeck('Lang');
    await store.createDeck('JP', parentId: lang);
    await store.createDeck('Lang2');
    await store.createDeck('A');

    final List<SrsDeckSummary> summaries = await store.deckSummaries();
    final List<SrsDeckChoice> choices = await srsDeckChoices(store);

    expect(
      summaries.length,
      greaterThanOrEqualTo(5),
      reason: '默认牌组 + 新建的 4 个；少了说明建牌组没生效，用例退化',
    );
    expect(
      <(String, String)>[
        for (final SrsDeckChoice c in choices) (c.id, c.fullName),
      ],
      <(String, String)>[
        for (final SrsDeckSummary s in summaries) (s.deck.id, s.fullName),
      ],
    );
    expect(choices.map((SrsDeckChoice c) => c.fullName), contains('Lang::JP'));
  });
}
