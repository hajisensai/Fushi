// 关联前续做迁移带过来的半截并入（G9-5 第二轮复核，srs_profile_link.dart `_resumePendingMerges`）：手里的副本还是旧
// uid 的，续做在它的最后一段独占区里跑、之后副本作废——改完主库 uid 之后、收尾前后经旧副本来的写入一律明确失败，
// 不会落进已经并走、删掉的旧 uid（内核写本机状态行时没有行就新建，漏进来的一条会让旧 uid 重新长出本机状态行）。
//
// 真主库 + 真内核：标记直接写进新代库的 `srs_meta`（同迁移带过来的形状），收尾走真的 `profile_merge_commit`。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

/// 半截并入的目标 uid（本机主库里没有这个 profile；新代库里也还没有它的集合）。
const String _kNewUid = '0193a1b2-0000-7000-8000-00000000cafe';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('续做半截并入：旧 uid 的副本作废、之后经它的写入明确失败；重开的是新 uid，旧 uid 的笔记并进来了', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrsStorage srs = await openTestSrsStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    final String oldUid = await db.profileUidOf(profileId);
    Future<SrsDbStore> openStore() async => SrsDbStore.open(
      core: srs.core,
      profileUid: await db.profileUidOf(profileId),
      deviceId: 'd',
    );
    SrsDbStore store = await openStore();
    final SrsDbStore old = store;
    await old.createNote(
      noteTypeId: old.lapisNoteTypeId,
      fieldsById: <String, String>{srsLapisFieldId(oldUid, 'Expression'): '鯨'},
    );
    srs.core.debugExecRaw(
      'INSERT INTO srs_meta (key, value) VALUES (?, ?)',
      <Object?>[
        'profile_merge/$oldUid',
        jsonEncode(<String, Object?>{
          'profileId': profileId,
          'newUid': _kNewUid,
        }),
      ],
    );
    final SrsDbProfileLinker linker = SrsDbProfileLinker(
      db: db,
      activeProfileId: () async => profileId,
      reopenStore: () async => store = await openStore(),
    );
    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_srs_merge_resume_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final SrsProfileLinkOutcome out = await linker.link(
      LocalDirectoryAssetStore(root),
      old,
    );

    expect(await db.profileUidOf(profileId), _kNewUid);
    expect(out.store.profileUid, _kNewUid);
    expect(identical(out.store, old), isFalse);
    expect(old.isUsable, isFalse, reason: '旧 uid 的副本作废');
    await expectLater(
      old.createDeck('并入之后才到的写入'),
      throwsA(isA<SrsStoreRetiredError>()),
    );
    final List<SrsNoteView> notes = await allNotesOf(out.store);
    expect(
      notes.map((SrsNoteView n) => n.fields.values.join()).toList(),
      contains(contains('鯨')),
      reason: '旧 uid 的笔记并进了新 uid',
    );
    final List<Map<String, Object?>> stale = srs.core.debugSelectRaw(
      'SELECT key FROM srs_meta WHERE key IN (?, ?)',
      <Object?>['profile_merge/$oldUid', 'local_state/$oldUid'],
    );
    expect(stale, isEmpty, reason: '标记与旧 uid 的本机状态行都删了、没有被写回来');
  });
}
