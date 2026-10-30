import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

/// 铁律 E：备份合并导入的 SRS 专用步骤（profiles 在主库、SRS 在各自的 srs.db，纯逻辑）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase backup;
  late SrsStorage backupSrs;
  late FushiDatabase local;
  late SrsStorage localSrs;

  setUp(() async {
    backup = FushiDatabase.forTesting(NativeDatabase.memory());
    local = FushiDatabase.forTesting(NativeDatabase.memory());
    backupSrs = await openTestSrsStorage();
    localSrs = await openTestSrsStorage();
  });
  tearDown(() async {
    await backup.close();
    await local.close();
  });

  Future<int> insertProfile(FushiDatabase db, String name) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.customStatement(
      'INSERT INTO profiles (name, created_at, updated_at) VALUES (?, ?, ?)',
      <Object>[name, now, now],
    );
    final QueryRow r = await db
        .customSelect(
          'SELECT id FROM profiles WHERE name = ?',
          variables: <Variable<Object>>[Variable<String>(name)],
        )
        .getSingle();
    return r.read<int>('id');
  }

  Future<String?> uidOfName(FushiDatabase db, String name) async {
    final QueryRow? r = await db
        .customSelect(
          'SELECT uid FROM profiles WHERE name = ?',
          variables: <Variable<Object>>[Variable<String>(name)],
        )
        .getSingleOrNull();
    return r?.read<String?>('uid');
  }

  Future<int> profileCount(FushiDatabase db) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM profiles').getSingle())
          .read<int>('c');

  Future<SrsDbStore> store(SrsStorage st, String uid, String device) =>
      SrsDbStore.open(
        db: st.db,
        core: st.core,
        profileUid: uid,
        deviceId: device,
      );

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  /// 备份里建一个名为 [name]、带一条笔记的 profile；返回 (uid, noteId)。
  Future<(String, String)> seedBackup(String name, String text) async {
    final int id = await insertProfile(backup, name);
    final String uid = await backup.profileUidOf(id);
    final SrsDbStore s = await store(backupSrs, uid, 'devB');
    return (uid, await addNote(s, text));
  }

  Future<int> createProfileIn(String name) => insertProfile(local, name);

  /// 老备份形态：srs_* 表在备份的主库里（用旧表定义建表，再把 [backupSrs] 的行原样抄过去）。
  Future<FushiDatabase> legacyBackupDb() async {
    final FushiDatabase legacy = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(legacy.close);
    for (final QueryRow r
        in await backup
            .customSelect(
              'SELECT id, name, created_at, updated_at, uid FROM profiles',
            )
            .get()) {
      await legacy.customStatement(
        'INSERT INTO profiles (id, name, created_at, updated_at, uid) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[
          r.read<int>('id'),
          r.read<String>('name'),
          r.read<int>('created_at'),
          r.read<int>('updated_at'),
          r.read<String?>('uid'),
        ],
      );
    }
    await copySrsRowsToLegacyTables(backupSrs.db, legacy);
    return legacy;
  }

  Future<List<SrsBackupMergeResult>> merge({bool legacy = false}) async =>
      mergeSrsFromBackup(
        source: legacy
            ? SrsBackupSource.database(await legacyBackupDb())
            : SrsBackupSource.split(profiles: backup, srs: backupSrs.db),
        local: local,
        localSrs: localSrs,
        deviceId: 'devA',
        createProfile: createProfileIn,
      );

  test('同 uid：直接合并进本机 profile', () async {
    final (String uid, String noteId) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '另一个名字');
    await local.adoptProfileUid(localId, uid);

    final List<SrsBackupMergeResult> r = await merge();
    expect(r, hasLength(1));
    expect(r.single.action, SrsBackupMergeAction.sameUid);
    expect(r.single.localProfileId, localId);
    expect(r.single.newEvents, greaterThan(0));

    final SrsDbStore s = await store(localSrs, uid, 'devA');
    final SrsNoteView? n = await s.note(noteId);
    expect(n!.field(srsLapisFieldId(uid, 'Expression')), '雪');
    expect(await s.cardsOfNote(noteId), hasLength(1));
    // 并入即发布（同步 v2 没有发件箱）：备份来源设备可能从未同步过，本机下一轮同步把这些操作传出去，
    // 同一 profile 的另一台设备从同步位置收到。
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    await srsSyncOnce(s, loc);
    final SrsDbStore peer = await store(
      await openTestSrsStorage(),
      uid,
      'devC',
    );
    await srsSyncOnce(peer, loc);
    expect(
      (await peer.note(noteId))?.field(srsLapisFieldId(uid, 'Expression')),
      '雪',
    );
    expect(await profileCount(local), 1);
  });

  test('同名、无用户笔记、未发布 → 采用备份 uid，旧 uid 的 SRS 行清掉', () async {
    final (String uid, String noteId) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '日语');
    final String oldUid = await local.profileUidOf(localId);
    // 本机打开过 SRS（内置行 + 本机状态），但没有笔记、没发布过。
    await store(localSrs, oldUid, 'devA');

    final List<SrsBackupMergeResult> r = await merge();
    expect(r.single.action, SrsBackupMergeAction.adoptedUid);
    expect(r.single.localProfileId, localId);
    expect(await uidOfName(local, '日语'), uid);
    for (final String table in <String>[
      'srs_entities',
      'srs_field_edits',
      'srs_event_local',
      'srs_local_state',
      'srs_notes_cache',
      'srs_cards_cache',
    ]) {
      final QueryRow c = await localSrs.db
          .customSelect(
            'SELECT COUNT(*) AS c FROM $table WHERE profile_uid = ?',
            variables: <Variable<Object>>[Variable<String>(oldUid)],
          )
          .getSingle();
      expect(c.read<int>('c'), 0, reason: '$table 不应残留旧 uid 的行');
    }
    final SrsDbStore s = await store(localSrs, uid, 'devA');
    expect(
      (await s.note(noteId))!.field(srsLapisFieldId(uid, 'Expression')),
      '雪',
    );
    expect(await profileCount(local), 1);
  });

  test('同名但有用户笔记 → 新建「（备份）」profile，本机数据不动', () async {
    final (String uid, String noteId) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '日语');
    final String oldUid = await local.profileUidOf(localId);
    final String localNote = await addNote(
      await store(localSrs, oldUid, 'devA'),
      '花',
    );

    final List<SrsBackupMergeResult> r = await merge();
    expect(r.single.action, SrsBackupMergeAction.createdProfile);
    expect(r.single.localProfileId, isNot(localId));
    expect(await uidOfName(local, '日语'), oldUid);
    expect(await uidOfName(local, '日语（备份）'), uid);

    // 事件 ID 全局唯一、不重映射：按 srs_entities.profile_uid 看归属。
    Future<String?> ownerOf(String id) async =>
        (await localSrs.db
                .customSelect(
                  'SELECT profile_uid FROM srs_entities WHERE id = ?',
                  variables: <Variable<Object>>[Variable<String>(id)],
                )
                .getSingleOrNull())
            ?.read<String>('profile_uid');
    expect(await ownerOf(localNote), oldUid);
    expect(await ownerOf(noteId), uid);
    final SrsDbStore copied = await store(localSrs, uid, 'devA');
    expect(await copied.note(noteId), isNotNull);
    expect(await copied.cardsOfNote(noteId), hasLength(1));
  });

  test('同名、没有笔记但传到过同步位置 → 不改 uid，新建「（备份）」', () async {
    final (String uid, _) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '日语');
    final String oldUid = await local.profileUidOf(localId);
    final SrsDbStore s = await store(localSrs, oldUid, 'devA');
    expect(await srsCanAdoptProfileUid(localSrs, oldUid), isTrue);
    // 同步 v2：传到过任何位置就算发布过（别的设备可能已经拿到这个身份下的操作）。
    await srsSyncOnce(s, SrsMemoryLocationStore());
    expect(await srsCanAdoptProfileUid(localSrs, oldUid), isFalse);

    final List<SrsBackupMergeResult> r = await merge();
    expect(r.single.action, SrsBackupMergeAction.createdProfile);
    expect(await uidOfName(local, '日语'), oldUid);
    expect(await uidOfName(local, '日语（备份）'), uid);
  });

  test('「（备份）」撞名时加序号', () {
    expect(srsBackupProfileName('A', <String>{}), 'A（备份）');
    expect(srsBackupProfileName('A', <String>{'A（备份）'}), 'A（备份 2）');
    expect(srsBackupProfileName('A', <String>{'A（备份）', 'A（备份 2）'}), 'A（备份 3）');
  });

  test('备份里只有内置行的 profile 不参与（不造空的「（备份）」）', () async {
    final int id = await insertProfile(backup, '只打开过');
    final String uid = await backup.profileUidOf(id);
    final SrsDbStore s = await store(backupSrs, uid, 'devB');
    expect(await s.hasUserNotes(), isFalse);
    expect(srsBuiltinEntities(uid), isNotEmpty);

    expect(await merge(), isEmpty);
    expect(await profileCount(local), 0);
  });

  test('合并两次幂等：第二次全部同 uid、零新增事件、profile 数不变', () async {
    final (String uid, String noteId) = await seedBackup('日语', '雪');
    await insertProfile(local, '日语');
    final int localId = (await insertProfile(local, '有数据'));
    final String otherUid = await local.profileUidOf(localId);
    await addNote(await store(localSrs, otherUid, 'devA'), '花');

    final List<SrsBackupMergeResult> first = await merge();
    expect(first.single.action, SrsBackupMergeAction.adoptedUid);
    final int profiles = await profileCount(local);
    final int events = (await (await store(
      localSrs,
      uid,
      'devA',
    )).exportAll()).length;

    final List<SrsBackupMergeResult> second = await merge();
    expect(second.single.action, SrsBackupMergeAction.sameUid);
    expect(second.single.newEvents, 0);
    expect(await profileCount(local), profiles);
    final SrsDbStore s = await store(localSrs, uid, 'devA');
    expect((await s.exportAll()).length, events);
    expect(await s.cardsOfNote(noteId), hasLength(1));
  });

  test('老备份形态（srs_* 表在备份主库里）：合并结果与新形态一致', () async {
    final (String uid, String noteId) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '另一个名字');
    await local.adoptProfileUid(localId, uid);

    final List<SrsBackupMergeResult> r = await merge(legacy: true);
    expect(r.single.action, SrsBackupMergeAction.sameUid);
    expect(r.single.newEvents, greaterThan(0));
    final SrsDbStore s = await store(localSrs, uid, 'devA');
    expect(
      (await s.note(noteId))!.field(srsLapisFieldId(uid, 'Expression')),
      '雪',
    );
  });

  test('srsCanAdoptProfileUid 只读：副本正开着时不另开副本、不写任何行；传到过同步位置就不能采用', () async {
    // 复习备份页「从文件恢复」时当前 profile 的副本正开着；判断「能不能改用备份的身份」若另开一个
    // SrsDbStore，会当场写本机状态 / 内置行，成了同一 profile 的第二个写者。
    final int localId = await insertProfile(local, '日语');
    final String uid = await local.profileUidOf(localId);
    await store(localSrs, uid, 'devA');
    Future<List<Object?>> snapshot() async => <Object?>[
      for (final QueryRow r
          in await localSrs.db
              .customSelect(
                'SELECT json FROM srs_local_state WHERE profile_uid = ?',
                variables: <Variable<Object>>[Variable<String>(uid)],
              )
              .get())
        r.read<String>('json'),
      (await localSrs.db
              .customSelect(
                'SELECT (SELECT COUNT(*) FROM srs_entities) + '
                '(SELECT COUNT(*) FROM srs_field_edits) + '
                '(SELECT COUNT(*) FROM srs_event_local) AS n',
              )
              .getSingle())
          .read<int>('n'),
    ];
    final List<Object?> before = await snapshot();
    expect(await srsCanAdoptProfileUid(localSrs, uid), isTrue);
    expect(await snapshot(), before);

    // 传到过同步位置 → 不能采用。
    await srsSyncOnce(
      await store(localSrs, uid, 'devA'),
      SrsMemoryLocationStore(),
    );
    expect(await srsCanAdoptProfileUid(localSrs, uid), isFalse);
  });

  test('srsAdoptProfileUid：清掉旧 uid 的 SRS 行并改写 profiles.uid', () async {
    final int localId = await insertProfile(local, '日语');
    final String oldUid = await local.profileUidOf(localId);
    await store(localSrs, oldUid, 'devA');
    expect(await srsCanAdoptProfileUid(localSrs, oldUid), isTrue);

    await srsAdoptProfileUid(
      local,
      localSrs.db,
      profileId: localId,
      oldUid: oldUid,
      newUid: 'new-uid',
    );
    expect(await uidOfName(local, '日语'), 'new-uid');
    final QueryRow c = await localSrs.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_entities WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(oldUid)],
        )
        .getSingle();
    expect(c.read<int>('c'), 0);
  });
}
