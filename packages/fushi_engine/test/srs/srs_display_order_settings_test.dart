// 牌组「出卡顺序」两项设置（复习顺序 reviewOrder / 新卡与复习 newMix）：wire 值往返、不认识的值回落缺省，
// 物化视图（Rust registers.rs 的 `ro` / `mx`）读得出来、随参数继承走 own 祖先。出卡规则本身在 Rust
// （native/fushi_fsrs store/study.rs 的测试），这里只钉 Dart 侧的值对象与寄存器读写。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kOrderProfile = '01928c3e-0000-7000-8000-0000000000d7';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('wire 值往返；没写 / 不认识的值回落缺省（与 Rust from_wire 同一条）', () {
    for (final SrsReviewCardOrder o in SrsReviewCardOrder.values) {
      expect(SrsReviewCardOrder.fromWire(o.wire), o);
    }
    for (final SrsNewCardMix m in SrsNewCardMix.values) {
      expect(SrsNewCardMix.fromWire(m.wire), m);
    }
    expect(
      <String>[
        for (final SrsReviewCardOrder o in SrsReviewCardOrder.values) o.wire,
      ],
      <String>[
        'retrievability',
        'dueDate',
        'difficulty',
        'intervalAscending',
        'random',
      ],
    );
    expect(
      <String>[for (final SrsNewCardMix m in SrsNewCardMix.values) m.wire],
      <String>['afterReviews', 'beforeReviews', 'mixed'],
    );
    expect(
      SrsReviewCardOrder.fromWire(null),
      SrsReviewCardOrder.retrievability,
    );
    expect(
      SrsReviewCardOrder.fromWire('easeDescending'),
      SrsReviewCardOrder.retrievability,
    );
    expect(SrsNewCardMix.fromWire(null), SrsNewCardMix.afterReviews);
    expect(SrsNewCardMix.fromWire('interleave'), SrsNewCardMix.afterReviews);
  });

  test('物化视图读出 reviewOrder / newMix；子牌组随参数继承，自己管参数的用自己的', () async {
    int t = DateTime.utc(2026, 11, 7, 12).millisecondsSinceEpoch;
    final SrsDbStore s = await openTestStore(
      profileUid: kOrderProfile,
      deviceId: 'a',
      now: () => t++,
    );
    final String root = await s.createDeck('Root');
    final String kid = await s.createDeck('Kid', parentId: root);
    final String own = await s.createDeck('Own', parentId: root);
    SrsDeckTree tree = await s.deckTree();
    expect(tree[root]!.reviewCardOrder, SrsReviewCardOrder.retrievability);
    expect(tree[root]!.newCardMix, SrsNewCardMix.afterReviews);

    await s.editFields(SrsEntityKind.deck, root, <String, Object?>{
      SrsFieldKeys.deckReviewOrder: SrsReviewCardOrder.difficulty.wire,
      SrsFieldKeys.deckNewMix: SrsNewCardMix.mixed.wire,
    });
    await s.editFields(SrsEntityKind.deck, own, <String, Object?>{
      SrsFieldKeys.deckParamsMode: 'own',
      SrsFieldKeys.deckReviewOrder: SrsReviewCardOrder.random.wire,
    });
    tree = await s.deckTree();
    expect(tree[root]!.reviewCardOrder, SrsReviewCardOrder.difficulty);
    expect(tree[root]!.newCardMix, SrsNewCardMix.mixed);
    expect(
      tree.paramsOwner(kid).reviewCardOrder,
      SrsReviewCardOrder.difficulty,
    );
    expect(tree.paramsOwner(kid).newCardMix, SrsNewCardMix.mixed);
    expect(tree.paramsOwner(own).reviewCardOrder, SrsReviewCardOrder.random);
    expect(tree.paramsOwner(own).newCardMix, SrsNewCardMix.afterReviews);

    // 更新版本写的、本机不认识的值：读成缺省，寄存器原样保留。
    await s.editFields(SrsEntityKind.deck, root, <String, Object?>{
      SrsFieldKeys.deckReviewOrder: 'relativeOverdueness',
    });
    tree = await s.deckTree();
    expect(tree[root]!.reviewCardOrder, SrsReviewCardOrder.retrievability);
    expect(
      tree[root]!.edits[SrsFieldKeys.deckReviewOrder]!.value,
      'relativeOverdueness',
    );
  });
}
