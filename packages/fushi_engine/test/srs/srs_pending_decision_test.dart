// BUG-3797：带标签的笔记删掉后一直挂在冲突中心「等你决定的笔记」里（「一台设备删除了这条笔记，另一台设备同时
// 修改了它」），点「确认删除」也消不掉。根因在寄存器内核：标签 OR-Set 投影出的合成 `tags` 行没有因果 dot，
// 被当成「与删除并发的修改」（native/fushi_fsrs/src/registers.rs `concurrent_with_delete`）。这里走真实的
// SrsDbStore → Rust 投影 → 笔记缓存路径，锁住冲突中心读的 `notesPendingDecision` 与编辑页读的
// `SrsNoteView.hasPendingDecision`，以及老库错标的待裁决在缓存修订号 5 升级时被重算掉。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e1';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SrsStorage st;

  setUp(() async {
    st = await openTestSrsStorage();
  });

  Future<SrsDbStore> open() => SrsDbStore.open(
    db: st.db,
    core: st.core,
    profileUid: kProfile,
    deviceId: 'dev',
  );

  String lapis(String key) => srsLapisFieldId(kProfile, key);

  Future<String> taggedNote(SrsDbStore s) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{lapis('Expression'): '鋾'},
    tags: const <String>['vocab', 'mined'],
  );

  test('删掉带标签的笔记：已删、不待裁决，冲突中心「等你决定的笔记」为空', () async {
    final SrsDbStore s = await open();
    final String id = await taggedNote(s);
    await s.deleteNote(id);

    final SrsNoteView? n = await s.note(id);
    expect(n!.deletedAt, isNotNull);
    expect(n.hasPendingDecision, isFalse);
    expect(await s.notesPendingDecision(), isEmpty);
    expect(await s.pendingDecisionCount(), 0);
    expect(await s.sync2Conflicts(), isEmpty);

    // 「确认删除」= 再删一次：照样已删、不待裁决。
    await s.deleteNote(id);
    expect((await s.note(id))!.hasPendingDecision, isFalse);
    expect(await s.notesPendingDecision(), isEmpty);
  });

  test('老库（缓存修订号 4）里错标成待裁决的已删笔记，打开时重算掉', () async {
    final SrsDbStore s = await open();
    final String id = await taggedNote(s);
    await s.deleteNote(id);
    // 还原修复前的缓存状态：这条已删笔记被错标成待裁决、本机缓存是修订号 4 推导的。
    await st.db.customStatement(
      'UPDATE srs_notes_cache SET pending_decision = 1',
    );
    await st.db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 4)",
    );
    expect(
      <String>[for (final r in await s.notesPendingDecision()) r.id],
      <String>[id],
    );

    final SrsDbStore reopened = await open();
    expect(await reopened.notesPendingDecision(), isEmpty);
    final String json =
        (await st.db
                .customSelect('SELECT json FROM srs_local_state')
                .getSingle())
            .read<String>('json');
    expect((jsonDecode(json) as Map)['cacheRev'], 5);
  });
}
