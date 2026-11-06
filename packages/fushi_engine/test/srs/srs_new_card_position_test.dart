// 新卡出卡位置（卡片修改记录 `newPos` → srs_cards_cache.new_position，v123）：
// 「按词频重排新卡」在 Fushi 复习下的存储层——出卡顺序、取卡、写回、同步合并。
import 'dart:convert';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';

const String kPosProfile = '01928c3e-0000-7000-8000-0000000000b7';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 20, 12).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 20, 12).millisecondsSinceEpoch;
  });

  Future<SrsDbStore> open([String device = 'a']) =>
      openTestStore(profileUid: kPosProfile, deviceId: device, now: () => t);

  /// 依次建笔记（创建时刻逐个递增），返回各自唯一那张卡的 id。
  Future<List<String>> addNotes(SrsDbStore s, List<String> words) async {
    final List<String> out = <String>[];
    for (final String w in words) {
      t += 1000;
      final String noteId = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kPosProfile, 'Expression'): w,
        },
      );
      out.add((await s.cardsOfNote(noteId)).single.id);
    }
    return out;
  }

  Future<String> defaultDeckName(SrsDbStore s) async =>
      (await s.deckTree()).fullName(s.defaultDeckId);

  /// 从默认牌组按出卡顺序把新卡全部学掉，返回出卡顺序。
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

  test('从没排过：出卡与取卡都按笔记创建时刻（老数据顺序不变），位置按顺序接着编号', () async {
    final SrsDbStore s = await open();
    final List<String> cards = await addNotes(s, <String>['一', '二', '三']);
    final List<SrsNewCardEntry> entries = await s.newCardsInDeck(
      await defaultDeckName(s),
    );
    expect(entries.map((SrsNewCardEntry e) => e.card.id), cards);
    expect(entries.map((SrsNewCardEntry e) => e.position), <int>[1, 2, 3]);
    expect(
      entries.every((SrsNewCardEntry e) => e.card.newPosition == null),
      isTrue,
    );
    expect(await drain(s), cards);
  });

  test('写位置后按位置出卡；没排过的接在后面、彼此仍按创建时刻', () async {
    final SrsDbStore s = await open();
    final List<String> c = await addNotes(s, <String>['一', '二', '三', '四']);
    final Set<String> accepted = await s.setNewCardPositions(<String, int>{
      c[2]: 1,
      c[0]: 2,
    });
    expect(accepted, <String>{c[2], c[0]});
    expect((await s.cardRow(c[2]))!.newPosition, 1);

    final List<SrsNewCardEntry> entries = await s.newCardsInDeck(
      await defaultDeckName(s),
    );
    expect(entries.map((SrsNewCardEntry e) => e.card.id), <String>[
      c[2],
      c[0],
      c[1],
      c[3],
    ]);
    // 没排过的两张接在已排的最大位置后面（只供比较，不落库）。
    expect(entries.map((SrsNewCardEntry e) => e.position), <int>[1, 2, 3, 4]);
    expect((await s.cardRow(c[1]))!.newPosition, isNull);
    expect(await drain(s), <String>[c[2], c[0], c[1], c[3]]);
  });

  test('只写此刻仍是新卡的：学过的卡不接受、不产生修改记录', () async {
    final SrsDbStore s = await open();
    final List<String> c = await addNotes(s, <String>['一', '二']);
    await s.answer(c[0], 4);
    final Set<String> accepted = await s.setNewCardPositions(<String, int>{
      c[0]: 5,
      c[1]: 6,
      'no-such-card': 7,
    });
    expect(accepted, <String>{c[1]});
    final SrsEntityEdits edits = await s.entityEdits(SrsEntityKind.card, c[0]);
    expect(edits[SrsFieldKeys.cardNewPosition], isNull);
    // 学过的卡不在取卡结果里。
    expect(
      (await s.newCardsInDeck(
        await defaultDeckName(s),
      )).map((SrsNewCardEntry e) => e.card.id),
      <String>[c[1]],
    );
  });

  test('子牌组算在内；不存在的牌组名返回空', () async {
    final SrsDbStore s = await open();
    final String child = await s.ensureDeckPath(
      '${await defaultDeckName(s)}::子',
    );
    t += 1000;
    final String noteId = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kPosProfile, 'Expression'): '子',
      },
      deckId: child,
    );
    final String cardId = (await s.cardsOfNote(noteId)).single.id;
    expect(
      (await s.newCardsInDeck(
        await defaultDeckName(s),
      )).map((SrsNewCardEntry e) => e.card.id),
      contains(cardId),
    );
    expect(await s.newCardsInDeck('不存在'), isEmpty);
  });

  test('位置随同步走；两台设备各自重排同一张卡：最后修改生效、不进同步冲突记录', () async {
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

    final List<String> c = await addNotes(a, <String>['一', '二']);
    await syncAll();
    await a.setNewCardPositions(<String, int>{c[1]: 1, c[0]: 2});
    await syncAll();
    expect((await b.cardRow(c[1]))!.newPosition, 1);
    expect(await b.nextCard(b.defaultDeckId), c[1]);

    // 并发：互相没看见对方的修改。
    await a.setNewCardPositions(<String, int>{c[0]: 10});
    t += 1000;
    await b.setNewCardPositions(<String, int>{c[0]: 20});
    await syncAll();
    expect((await a.cardRow(c[0]))!.newPosition, 20);
    expect((await b.cardRow(c[0]))!.newPosition, 20);
    expect(await a.syncConflicts(), isEmpty);
    expect(await b.syncConflicts(), isEmpty);
  });

  test('旧版本设备收下的 newPos：升级后打开时定向重算缓存（只做一次）', () async {
    final SrsDbStore a = await open();
    final List<String> c = await addNotes(a, <String>['一', '二', '三']);
    await a.setNewCardPositions(<String, int>{c[2]: 1});

    // 模拟 v123 之前的设备：修改记录已落库，缓存没有这一列（升级加列后为 NULL），
    // 本机状态里也没有缓存版本。
    Future<void> asPreV123() async {
      await a.db.customStatement(
        'UPDATE srs_cards_cache SET new_position = NULL WHERE profile_uid = srs_id(?)',
        <Object>[kPosProfile],
      );
      final String json =
          (await a.db
                  .customSelect(
                    'SELECT json FROM srs_local_state WHERE profile_uid = ?',
                    variables: <Variable<Object>>[
                      Variable<String>(kPosProfile, srsIdType),
                    ],
                  )
                  .getSingle())
              .read<String>('json');
      final Map<String, Object?> j =
          (jsonDecode(json) as Map).cast<String, Object?>()..remove('cacheRev');
      await a.db.customStatement(
        'UPDATE srs_local_state SET json = ? WHERE profile_uid = srs_id(?)',
        <Object>[jsonEncode(j), kPosProfile],
      );
    }

    Future<SrsDbStore> reopen() => SrsDbStore.open(
      db: a.db,
      core: a.core,
      profileUid: kPosProfile,
      deviceId: 'a',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-a',
      ),
      fallbackRolloverHour: () => 4,
    );

    await asPreV123();
    expect((await a.cardRow(c[2]))!.newPosition, isNull);
    expect(await a.nextCard(a.defaultDeckId), c[0], reason: '前提：缓存是旧的');

    final SrsDbStore upgraded = await reopen();
    expect((await upgraded.cardRow(c[2]))!.newPosition, 1);
    expect((await upgraded.cardRow(c[0]))!.newPosition, isNull);
    expect(await upgraded.nextCard(upgraded.defaultDeckId), c[2]);

    // 记下了缓存版本：之后再打开不再扫修改记录表（手动清掉的值不会被补回）。
    await a.db.customStatement(
      'UPDATE srs_cards_cache SET new_position = NULL WHERE profile_uid = srs_id(?)',
      <Object>[kPosProfile],
    );
    final SrsDbStore again = await reopen();
    expect((await again.cardRow(c[2]))!.newPosition, isNull);
  });

  test('字段类别：newPos 按界面状态（最后修改生效、不报冲突）', () {
    expect(
      srsFieldClassOf(SrsEntityKind.card, SrsFieldKeys.cardNewPosition),
      SrsFieldClass.viewState,
    );
    expect(
      srsFieldClassOf(SrsEntityKind.card, SrsFieldKeys.suspended),
      SrsFieldClass.flag,
    );
  });
}
