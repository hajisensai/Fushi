// 每日上限单位改缺省（卡片数 → 作答次数，拍板台 pr3460）后的两项跟进：
// - 存量牌组的一次性提醒判据（[SrsDbStore.limitUnitLegacyDecks]）：没写过单位、且在改缺省之前评过分；新建牌组明写单位；
// - 分钟单位的牌组在计数里带今天还剩的复习分钟（[SrsDeckSummary.reviewMinutesLeft]），牌组列表显示它而不是张数。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000003a6';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const int day = 86400000;

  Future<String> noteIn(SrsDbStore s, String deckId, String expr) async {
    final String note = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      deckId: deckId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expr,
      },
    );
    return (await s.cardsOfNote(note)).single.id;
  }

  test('存量牌组：没写过单位且改缺省之前评过分（按子树）才算；新建牌组明写作答次数；写了单位后不再算', () async {
    int t = kSrsLimitUnitDefaultChangedAtMs - 10 * day;
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    // 内置默认牌组从没写过单位；新装时还没评过分，不算存量（新用户不该收到「以前按卡片数」的提醒）。
    expect((await s.deckTree())[s.defaultDeckId]!.limitUnitSet, isFalse);
    expect(await s.limitUnitLegacyDecks(), isEmpty);

    final String fresh = await s.createDeck('Fresh');
    final SrsDeckView freshView = (await s.deckTree())[fresh]!;
    expect(freshView.limitUnitSet, isTrue, reason: '新建牌组明写单位');
    expect(freshView.limitUnit, SrsLimitUnit.reviews);

    // 模拟加单位设置之前就有的牌组：单位寄存器为空。Old（没写单位）下挂 Kid（写了单位）。
    final String old = await s.createDeck('Old');
    final String kid = await s.createDeck('Kid', parentId: old);
    final String later = await s.createDeck('Later');
    for (final String d in <String>[old, later]) {
      await s.editFields(SrsEntityKind.deck, d, <String, Object?>{
        SrsFieldKeys.deckLimitUnit: null,
      });
    }
    expect((await s.deckTree())[old]!.limitUnitSet, isFalse);

    final String inDefault = await noteIn(s, s.defaultDeckId, '聞く');
    final String inKid = await noteIn(s, kid, '話す');
    final String inFresh = await noteIn(s, fresh, '読む');
    final String inLater = await noteIn(s, later, '書く');
    t += 1000;
    await s.answer(inDefault, 3);
    await s.answer(inKid, 3);
    await s.answer(inFresh, 3);
    // Later 在改缺省之后才评分：它从没按卡片数计过上限。
    t = kSrsLimitUnitDefaultChangedAtMs + 1000;
    await s.answer(inLater, 3);

    expect(await s.limitUnitLegacyDecks(), <String>{
      s.defaultDeckId,
      old,
    }, reason: '默认牌组自己评过分；Old 的子树（Kid）评过分；Kid / Fresh 写了单位；Later 是改缺省之后才用的');

    // 回应提醒（明写单位）之后不再算。
    await s.editFieldsBatch(<SrsFieldChange>[
      SrsFieldChange(
        SrsEntityKind.deck,
        s.defaultDeckId,
        SrsFieldKeys.deckLimitUnit,
        SrsLimitUnit.cards.wire,
      ),
      SrsFieldChange(
        SrsEntityKind.deck,
        old,
        SrsFieldKeys.deckLimitUnit,
        SrsLimitUnit.reviews.wire,
      ),
    ]);
    expect(await s.limitUnitLegacyDecks(), isEmpty);
    final SrsDeckTree after = await s.deckTree();
    expect(after[s.defaultDeckId]!.limitUnit, SrsLimitUnit.cards);
    expect(after[old]!.limitUnit, SrsLimitUnit.reviews);
  });

  test('分钟单位的牌组计数带今天还剩的复习分钟；其余单位没有；线格式往返保留', () async {
    const int t = kSrsLimitUnitDefaultChangedAtMs + 5 * day;
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'b',
      now: () => t,
    );
    final String minutes = await s.createDeck('Minutes');
    final String counts = await s.createDeck('Counts');
    for (final (String d, SrsLimitUnit u) in <(String, SrsLimitUnit)>[
      (minutes, SrsLimitUnit.minutes),
      (counts, SrsLimitUnit.cards),
    ]) {
      await s.editFields(SrsEntityKind.deck, d, <String, Object?>{
        SrsFieldKeys.deckLimits: <String, Object?>{'new': 20, 'review': 30},
        SrsFieldKeys.deckLimitUnit: u.wire,
      });
    }
    final SrsDeckSummary m = (await s.deckSummary(minutes))!;
    final SrsDeckSummary c = (await s.deckSummary(counts))!;
    expect(m.reviewMinutesLeft, 30, reason: '今天还没复习：剩整 30 分钟');
    expect(c.reviewMinutesLeft, isNull);
    expect(
      (await s.deckSummaries())
          .singleWhere((SrsDeckSummary d) => d.deck.id == minutes)
          .reviewMinutesLeft,
      30,
      reason: '牌组列表与单个牌组同一份计数',
    );

    final SrsDeckTree tree = await s.deckTree();
    for (final SrsDeckSummary row in <SrsDeckSummary>[m, c]) {
      final SrsDeckSummary back = SrsRemoteWire.summaryFrom(
        jsonDecode(jsonEncode(SrsRemoteWire.summary(row))),
        tree,
      )!;
      expect(back.reviewMinutesLeft, row.reviewMinutesLeft);
    }
  });
}
