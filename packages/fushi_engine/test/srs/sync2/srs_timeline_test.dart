// 时间线（docs/specs/2026-10-25-srs-sync-v2-design.md §10.2）在真实 SrsDbStore 上：删牌组连笔记之前自动打
// `bulk_delete` 还原点；预览 / 恢复到删除之前，被删的笔记复活（内容、复习照旧）；恢复前自动打 `restore` 还原点，
// 恢复本身可再恢复回去；恢复的补偿操作照常同步到别的设备。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_sync2_peers.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f4';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;

  setUp(() => t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch);

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');

  Future<String> addNote(SrsDbStore s, String text, {String? deckId}) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{expr(s): text},
      deckId: deckId,
    );
  }

  Future<List<String>> reasons(SrsDbStore s) async => <String>[
    for (final Map<String, Object?> c in await s.sync2Checkpoints())
      '${c['reason']}',
  ];

  /// 一个牌组里两条笔记（一条复习过）+ 牌组外一条，删牌组连笔记。返回 (被删笔记, 复习过的卡, 牌组外笔记)。
  Future<(List<String>, String, String)> seedAndDelete(SrsDbStore a) async {
    final String deck = await a.ensureDeckPath('N3');
    final String n1 = await addNote(a, '海', deckId: deck);
    final String n2 = await addNote(a, '山', deckId: deck);
    final String outside = await addNote(a, '空');
    final String card = (await a.cardsOfNote(n1)).single.id;
    t += 60 * 1000;
    await a.answer(card, 3);
    expect(await reasons(a), isNot(contains('bulk_delete')));
    t += 60 * 1000;
    final List<String> deleted = await a.deleteDeck(deck, deleteCards: true);
    expect(deleted.toSet(), <String>{n1, n2});
    return (deleted, card, outside);
  }

  Future<void> expectRevived(
    SrsDbStore s,
    List<String> notes,
    String card,
  ) async {
    for (final String n in notes) {
      final SrsNoteView? v = await s.note(n);
      expect(v, isNotNull);
      expect(v!.deletedAt, isNull, reason: '$n 复活');
    }
    expect((await s.note(notes.first))!.field(expr(s)), anyOf('海', '山'));
    expect((await s.cardRow(card))!.hidden, isFalse);
    expect((await s.cardRow(card))!.reps, 1, reason: '复习历史照旧');
  }

  test('删牌组连笔记 → 自动 bulk_delete 还原点；只删空牌组不打', () async {
    final SrsDbStore a = await device('a');
    final String empty = await a.ensureDeckPath('Empty');
    await a.deleteDeck(empty, deleteCards: true);
    expect(await reasons(a), isNot(contains('bulk_delete')), reason: '没删笔记');
    await seedAndDelete(a);
    final List<Map<String, Object?>> cps = await a.sync2Checkpoints();
    expect(cps.first['reason'], 'bulk_delete', reason: '新的在前');
    expect(cps.first['name'], 'N3');
    expect(cps.first['at'], isA<int>());
  });

  test('恢复到删除之前：预览数对、笔记复活；恢复前自动打 restore 还原点；恢复本身可再恢复回去', () async {
    final SrsDbStore a = await device('a');
    final String deck = await a.ensureDeckPath('N3');
    final String n1 = await addNote(a, '海', deckId: deck);
    final String n2 = await addNote(a, '山', deckId: deck);
    final String outside = await addNote(a, '空');
    final String card = (await a.cardsOfNote(n1)).single.id;
    t += 60 * 1000;
    await a.answer(card, 3);
    t += 60 * 1000;
    final int beforeDelete = t;
    t += 60 * 1000;
    await a.deleteDeck(deck, deleteCards: true);
    expect((await a.note(n1))!.deletedAt, isNotNull);

    t += 60 * 1000;
    final Map<String, Object?> plan = await a.sync2PlanRestore(
      beforeDelete,
      retractReviews: false,
    );
    expect(plan['revived'], greaterThanOrEqualTo(2), reason: '$plan');
    expect(plan['reviews'], 0, reason: '那之后没有复习：$plan');
    expect((await a.note(n1))!.deletedAt, isNotNull, reason: '预览不改任何东西');

    await a.sync2Restore(beforeDelete, retractReviews: false);
    await expectRevived(a, <String>[n1, n2], card);
    expect((await a.note(outside))!.deletedAt, isNull);
    final List<Map<String, Object?>> cps = await a.sync2Checkpoints();
    expect(cps.first['reason'], 'restore', reason: '恢复前先打还原点');
    expect(<String>[
      for (final Map<String, Object?> c in cps) '${c['reason']}',
    ], containsAll(<String>['restore', 'bulk_delete']));

    // 恢复本身可撤销：回到恢复之前（笔记又是删除状态）。
    final int restoredAt = (cps.first['at']! as int) - 1;
    t += 60 * 1000;
    await a.sync2Restore(restoredAt, retractReviews: false);
    expect((await a.note(n1))!.deletedAt, isNotNull);
    expect((await a.note(n2))!.deletedAt, isNotNull);
  });

  test('界面路径：恢复到 bulk_delete 还原点自己的时刻，删掉的笔记回来', () async {
    // 时间线页点还原点 = 按那个还原点的因果恢复（checkpoint 参数）。还原点与随后的删除常在同一毫秒内落下
    // （这里时钟不走，必然同毫秒）；按「墙钟 <= at」截断会把删除也算进那一刻，所以不能只传时刻。
    final SrsDbStore a = await device('a');
    final (List<String> deleted, String card, _) = await seedAndDelete(a);
    final Map<String, Object?> cp = (await a.sync2Checkpoints()).firstWhere(
      (Map<String, Object?> c) => c['reason'] == 'bulk_delete',
    );
    t += 60 * 1000;
    final ({String device, int seq}) id = (
      device: cp['device']! as String,
      seq: cp['seq']! as int,
    );
    final Map<String, Object?> plan = await a.sync2PlanRestore(
      cp['at']! as int,
      retractReviews: false,
      checkpoint: id,
    );
    expect(plan['revived'], greaterThanOrEqualTo(2), reason: '$plan');
    await a.sync2Restore(
      cp['at']! as int,
      retractReviews: false,
      checkpoint: id,
    );
    await expectRevived(a, deleted, card);
  });

  test('恢复的补偿操作同步到别的设备：那边的笔记也复活，两端摘要一致', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String deck = await a.ensureDeckPath('N3');
    final String n1 = await addNote(a, '海', deckId: deck);
    final String card = (await a.cardsOfNote(n1)).single.id;
    t += 60 * 1000;
    await a.answer(card, 3);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    t += 60 * 1000;
    final int beforeDelete = t;
    t += 60 * 1000;
    await a.deleteDeck(deck, deleteCards: true);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect((await b.note(n1))!.deletedAt, isNotNull);

    t += 60 * 1000;
    await a.sync2Restore(beforeDelete, retractReviews: false);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect((await b.note(n1))!.deletedAt, isNull);
    expect((await b.note(n1))!.field(expr(b)), '海');
    expect((await b.cardRow(card))!.reps, 1);
    expect(await b.sync2Conflicts(), isEmpty);
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
  });
}
