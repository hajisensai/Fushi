// 每日上限单位改缺省（卡片数 → 作答次数，拍板台 pr3460）后的两项跟进：
// - 存量牌组的一次性提醒判据（[SrsDbStore.limitUnitLegacyDecks]）：没写过单位、且在**本机第一次跑懂单位的版本之前**
//   （本机状态行 `limitUnitSince`，开库时记下）在 Fushi 里评过分；从 Anki 导入的复习不算（拍板台 left3551）；新建牌组
//   明写单位；
// - 分钟单位的牌组在计数里带今天还剩的复习分钟（[SrsDeckSummary.reviewMinutesLeft]），牌组列表显示它而不是张数。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000003a6';

/// 本机第一次开库（= 第一次跑懂单位的版本）的时刻。
final int kUpgradedAt = DateTime.utc(2026, 11, 20, 12).millisecondsSinceEpoch;

const int kAnkiMid = 1700000000077;
const int kAnkiDeck = 1700000000010;

/// 一个 Anki 包：一条笔记一张卡，带两条复习历史（都在 [kUpgradedAt] 之前）。
Uint8List ankiPackageWithHistory() {
  final int day1 = DateTime.utc(2026, 9, 6, 10).millisecondsSinceEpoch;
  return zipOf(<String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: DateTime.utc(2026, 1, 1, 4).millisecondsSinceEpoch ~/ 1000,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
      models: <String, Object?>{
        '$kAnkiMid': <String, Object?>{
          'id': kAnkiMid,
          'name': 'Basic',
          'type': 0,
          'css': '',
          'flds': <Object?>[
            <String, Object?>{'name': 'Front', 'ord': 0, 'id': 9000},
            <String, Object?>{'name': 'Back', 'ord': 1, 'id': 9001},
          ],
          'tmpls': <Object?>[
            <String, Object?>{
              'name': 'Card 1',
              'ord': 0,
              'qfmt': '{{Front}}',
              'afmt': '{{Back}}',
              'id': 9100,
            },
          ],
        },
      },
      decks: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
        '$kAnkiDeck': <String, Object?>{
          'id': kAnkiDeck,
          'name': '日本語',
          'dyn': 0,
          'conf': 1,
        },
      },
      dconf: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default'},
      },
      notes: <FxNote>[
        FxNote(
          id: day1 - 86400000 * 30,
          guid: 'g0',
          mid: kAnkiMid,
          fields: <String>['語', 'word'],
          cards: <FxCard>[
            FxCard(
              id: 100,
              ord: 0,
              did: kAnkiDeck,
              type: 2,
              queue: 2,
              due: 300,
              ivl: 10,
              factor: 2500,
              reps: 2,
              revlog: <FxRevlog>[
                FxRevlog(day1 - 86400000 * 3, type: 0, ease: 3, ivl: 1),
                FxRevlog(day1, type: 1, ease: 3, ivl: 10),
              ],
            ),
          ],
        ),
      ],
    ),
    'media': utf8.encode('{}'),
  });
}

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

  Future<void> clearUnit(SrsDbStore s, String deckId) => s.editFields(
    SrsEntityKind.deck,
    deckId,
    <String, Object?>{SrsFieldKeys.deckLimitUnit: null},
  );

  test('存量牌组：没写过单位且本机升级之前评过分（按子树）才算；升级之后才用的、新建牌组、写了单位的不算', () async {
    int t = kUpgradedAt;
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    // 内置默认牌组从没写过单位；新装时本机还没评过分，不算存量（新用户不该收到「以前按卡片数」的提醒）。
    expect((await s.deckTree())[s.defaultDeckId]!.limitUnitSet, isFalse);
    expect(await s.limitUnitLegacyDecks(), isEmpty);

    final String fresh = await s.createDeck('Fresh');
    final SrsDeckView freshView = (await s.deckTree())[fresh]!;
    expect(freshView.limitUnitSet, isTrue, reason: '新建牌组明写单位');
    expect(freshView.limitUnit, SrsLimitUnit.reviews);

    // 模拟旧版建的牌组：单位寄存器为空。Old（没写单位）下挂 Kid（写了单位）。
    final String old = await s.createDeck('Old');
    final String kid = await s.createDeck('Kid', parentId: old);
    final String later = await s.createDeck('Later');
    for (final String d in <String>[old, later]) {
      await clearUnit(s, d);
    }
    expect((await s.deckTree())[old]!.limitUnitSet, isFalse);

    final String inDefault = await noteIn(s, s.defaultDeckId, '聞く');
    final String inKid = await noteIn(s, kid, '話す');
    final String inFresh = await noteIn(s, fresh, '読む');
    final String inLater = await noteIn(s, later, '書く');
    // 本机升级之前的复习（时钟拨回：旧版做的、迁移 / 同步进来的历史都在 limitUnitSince 之前）。缺省改动合入之后、
    // 本机升级之前用旧版做的复习同样算——判据看本机升级时刻，不看合入时刻。
    t = kUpgradedAt - 10 * day;
    await s.answer(inDefault, 3);
    await s.answer(inKid, 3);
    await s.answer(inFresh, 3);
    // Later 在本机升级之后才评分：它从没按卡片数计过上限。
    t = kUpgradedAt + 1000;
    await s.answer(inLater, 3);

    expect(await s.limitUnitLegacyDecks(), <String>{
      s.defaultDeckId,
      old,
    }, reason: '默认牌组自己评过分；Old 的子树（Kid）评过分；Kid / Fresh 写了单位；Later 是升级之后才用的');

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

  test('本机升级时刻只记一次：同一份库重开（时钟往后走）沿用第一次开库的时刻', () async {
    int t = kUpgradedAt;
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore first = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
      storage: storage,
    );
    final String card = await noteIn(first, first.defaultDeckId, '聞く');
    t = kUpgradedAt + 5 * day;
    await first.answer(card, 3);
    expect(await first.limitUnitLegacyDecks(), isEmpty);

    // 重开时刻在那次评分之后：要是每次开库都重记，那次评分就成了「升级之前」。
    t = kUpgradedAt + 10 * day;
    final SrsDbStore reopened = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
      storage: storage,
    );
    expect(await reopened.limitUnitLegacyDecks(), isEmpty);
  });

  test('从 Anki 导入的复习历史不算存量（即使牌组没写过单位、历史早于本机升级）；本机升级前在 Fushi 里的复习算', () async {
    int t = kUpgradedAt;
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    await importAnkiPackage(
      store: s,
      bytes: ankiPackageWithHistory(),
      storeMedia: (String n, Uint8List b) async => 'h_$n',
      options: const SrsAnkiImportOptions(
        withScheduling: true,
        withDeckConfigs: true,
      ),
      zstdDecompress: (Uint8List b) => null,
    );
    final List<SrsNoteCacheRow> notes = await s.listNotes(limit: 10);
    final SrsCardCacheRow card = (await s.cardsOfNote(notes.single.id)).single;
    expect(
      (await s.history(card.id)).effective.where(
        (SrsReviewLog l) =>
            l.origin == SrsLogOrigin.anki && l.kind == SrsLogKind.review,
      ),
      hasLength(2),
      reason: '前提：两条 Anki 复习历史导进来了',
    );
    // 模拟旧版导入（那时导入新建的牌组不写单位）：导入的牌组及其祖先都清掉单位。
    final SrsDeckTree tree = await s.deckTree();
    final List<String> chain = <String>[
      for (String? d = card.deckId; d != null; d = tree[d]?.parentId) d,
    ];
    for (final String d in chain) {
      await clearUnit(s, d);
    }
    expect(
      await s.limitUnitLegacyDecks(),
      isEmpty,
      reason: 'Anki 历史从没受过 Fushi 的每日上限',
    );

    // 本机升级之前在 Fushi 里复习过这张卡：这个牌组（与祖先）按卡片数计过上限，算存量。
    t = kUpgradedAt - day;
    await s.answer(card.id, 3);
    expect(await s.limitUnitLegacyDecks(), chain.toSet());
  });

  test('分钟单位的牌组计数带今天还剩的复习分钟；其余单位没有；线格式往返保留', () async {
    final int t = kUpgradedAt + 5 * day;
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
