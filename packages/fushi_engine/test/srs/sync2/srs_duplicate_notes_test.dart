// 重复笔记的合并建议（docs/specs/2026-10-25-srs-sync-v2-design.md §5.4）：两台设备各自制了同一个词，同步后
// 给出建议；合并后保留卡的调度由两边复习历史一起重放得出，另一台设备同步后得到同样的结果。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_sync2_peers.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000de';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
  }

  Future<String> addNote(SrsDbStore s, String expression, String reading) =>
      s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): expression,
          srsLapisReadingFieldId(kProfile): reading,
        },
      );

  Future<String> firstCard(SrsDbStore s, String note) async =>
      (await s.cardsOfNote(note)).first.id;

  Future<String> stateOf(SrsDbStore s, String card) async =>
      srsCanonicalJson((await s.history(card)).state.toJson());

  test('两台设备各制同一个词：同步后建议合并，合并后历史合在一起、两端一致', () async {
    final SrsLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final String na = await addNote(a, '雪', 'ゆき');
    final String nb = await addNote(b, '雪', 'ゆき');
    await addNote(a, '雨', 'あめ');
    final String ca = await firstCard(a, na);
    final String cb = await firstCard(b, nb);
    await a.answer(ca, 3);
    await a.answer(ca, 3);
    await b.answer(cb, 1);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);

    final List<SrsDuplicateGroup> groups = await a.duplicateNoteGroups();
    expect(groups, hasLength(1));
    expect(groups.single.noteIds.toSet(), <String>{na, nb});
    // 复习多的那条排在最前（建议保留）。
    expect(groups.single.noteIds.first, na);

    final SrsMergeReport r = await a.mergeNotes(
      keepId: na,
      absorbIds: <String>[nb],
    );
    expect(r.linkedCards, 1);
    expect(r.unmatchedCards, 0);
    expect(
      (await a.history(ca)).effective.length,
      3,
      reason: '两边三次复习都进了保留卡的重放',
    );
    expect(await a.duplicateNoteGroups(), isEmpty);
    expect(<String>[
      for (final Map<String, Object?> c in await a.sync2Checkpoints())
        c['reason']! as String,
    ], contains('merge_notes'));

    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    final SrsNoteView? absorbed = (await b.notes(<String>[nb]))[nb];
    expect(
      absorbed == null || absorbed.deletedAt != null,
      isTrue,
      reason: '被吸收的笔记在 B 上也删了',
    );
    expect(await stateOf(b, ca), await stateOf(a, ca));
    expect(await b.duplicateNoteGroups(), isEmpty);
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
  });

  test('「不是重复」随同步走，两台设备都不再建议', () async {
    final SrsLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    await addNote(a, '橋', 'はし');
    await addNote(b, '橋', 'はし');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    final List<SrsDuplicateGroup> g = await b.duplicateNoteGroups();
    expect(g, hasLength(1));
    await b.dismissDuplicates(g.single.noteIds);
    expect(await b.duplicateNoteGroups(), isEmpty);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect(await a.duplicateNoteGroups(), isEmpty);
  });

  test('读音不同不算重复；不同笔记类型不能合并', () async {
    final SrsDbStore a = await device('A');
    await addNote(a, '上手', 'じょうず');
    await addNote(a, '上手', 'うわて');
    expect(await a.duplicateNoteGroups(), isEmpty);
  });
}
