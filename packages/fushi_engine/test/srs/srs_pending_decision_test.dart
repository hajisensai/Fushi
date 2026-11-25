// BUG-3797：带标签的笔记删掉后一直挂在冲突中心「等你决定的笔记」里（「一台设备删除了这条笔记，另一台设备同时
// 修改了它」），点「确认删除」也消不掉。根因在寄存器内核：标签 OR-Set 投影出的合成 `tags` 行没有因果 dot，
// 被当成「与删除并发的修改」（native/fushi_fsrs/src/registers.rs `concurrent_with_delete`）。这里走真实的
// SrsDbStore → Rust 投影 → 笔记缓存路径，锁住冲突中心读的 `notesPendingDecision` 与编辑页读的
// `SrsNoteView.hasPendingDecision`，以及待裁决列被改坏后整层重建按真相算回「不待裁决」。

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

  Future<SrsDbStore> open() =>
      SrsDbStore.open(core: st.core, profileUid: kProfile, deviceId: 'dev');

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

  // 协议 3 的「老库（缓存修订号 4）错标的待裁决开库重算掉」改成整层重建：新代没有 `cacheRev`，协议 3 的旧库只经
  // 换代迁移整份重建派生层，这里锁住重建出来的也不待裁决：先经原始通道把 `notes.pending_decision` 错标成 1（老库
  // 错标的形态），重建必须按寄存器投影算回 0。
  test('删掉带标签的笔记、待裁决列错标后整层重建：算回不待裁决', () async {
    final SrsDbStore s = await open();
    final String id = await taggedNote(s);
    await s.deleteNote(id);
    await expectRebuildRestores(
      s,
      'notes',
      'UPDATE notes SET pending_decision = 1',
    );
    expect(await s.notesPendingDecision(), isEmpty);
    expect((await s.note(id))!.deletedAt, isNotNull);
    expect(await (await open()).notesPendingDecision(), isEmpty);
  });
}
