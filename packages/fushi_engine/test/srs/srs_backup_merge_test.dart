import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

/// 铁律 E：备份合并导入的 SRS 专用步骤（两个内存库，纯逻辑）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase backup;
  late FushiDatabase local;

  setUp(() {
    backup = FushiDatabase.forTesting(NativeDatabase.memory());
    local = FushiDatabase.forTesting(NativeDatabase.memory());
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

  Future<SrsDbStore> store(FushiDatabase db, String uid, String device) =>
      SrsDbStore.open(db: db, profileUid: uid, deviceId: device);

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
    final SrsDbStore s = await store(backup, uid, 'devB');
    return (uid, await addNote(s, text));
  }

  Future<int> createProfileIn(String name) => insertProfile(local, name);

  Future<List<SrsBackupMergeResult>> merge() => mergeSrsFromBackup(
    source: SrsBackupSource.database(backup),
    local: local,
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

    final SrsDbStore s = await store(local, uid, 'devA');
    final SrsNoteView? n = await s.note(noteId);
    expect(n!.field(srsLapisFieldId(uid, 'Expression')), '雪');
    expect(await s.cardsOfNote(noteId), hasLength(1));
    // 新事件重新进本机发件箱（备份来源设备可能从未同步过）。
    expect(
      (await s.unpublishedEvents()).map((SrsEvent e) => e.id),
      contains(noteId),
    );
    expect(await profileCount(local), 1);
  });

  test('同名、无用户笔记、未发布 → 采用备份 uid，旧 uid 的 SRS 行清掉', () async {
    final (String uid, String noteId) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '日语');
    final String oldUid = await local.profileUidOf(localId);
    // 本机打开过 SRS（内置行 + 本机状态），但没有笔记、没发布过。
    await store(local, oldUid, 'devA');

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
      final QueryRow c = await local
          .customSelect(
            'SELECT COUNT(*) AS c FROM $table WHERE profile_uid = ?',
            variables: <Variable<Object>>[Variable<String>(oldUid)],
          )
          .getSingle();
      expect(c.read<int>('c'), 0, reason: '$table 不应残留旧 uid 的行');
    }
    final SrsDbStore s = await store(local, uid, 'devA');
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
      await store(local, oldUid, 'devA'),
      '花',
    );

    final List<SrsBackupMergeResult> r = await merge();
    expect(r.single.action, SrsBackupMergeAction.createdProfile);
    expect(r.single.localProfileId, isNot(localId));
    expect(await uidOfName(local, '日语'), oldUid);
    expect(await uidOfName(local, '日语（备份）'), uid);

    // 事件 ID 全局唯一、不重映射：按 srs_entities.profile_uid 看归属。
    Future<String?> ownerOf(String id) async =>
        (await local
                .customSelect(
                  'SELECT profile_uid FROM srs_entities WHERE id = ?',
                  variables: <Variable<Object>>[Variable<String>(id)],
                )
                .getSingleOrNull())
            ?.read<String>('profile_uid');
    expect(await ownerOf(localNote), oldUid);
    expect(await ownerOf(noteId), uid);
    final SrsDbStore copied = await store(local, uid, 'devA');
    expect(await copied.note(noteId), isNotNull);
    expect(await copied.cardsOfNote(noteId), hasLength(1));
  });

  test('同名、没有笔记但发布过批次 → 不改 uid，新建「（备份）」', () async {
    final (String uid, _) = await seedBackup('日语', '雪');
    final int localId = await insertProfile(local, '日语');
    final String oldUid = await local.profileUidOf(localId);
    final SrsDbStore s = await store(local, oldUid, 'devA');
    await s.saveSyncState(
      SrsSyncLocalState(writerId: s.writerId, nextBatchNo: 2),
    );
    expect(s.everPublished, isTrue);

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
    final SrsDbStore s = await store(backup, uid, 'devB');
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
    await addNote(await store(local, otherUid, 'devA'), '花');

    final List<SrsBackupMergeResult> first = await merge();
    expect(first.single.action, SrsBackupMergeAction.adoptedUid);
    final int profiles = await profileCount(local);
    final int events = (await (await store(
      local,
      uid,
      'devA',
    )).exportAll()).length;

    final List<SrsBackupMergeResult> second = await merge();
    expect(second.single.action, SrsBackupMergeAction.sameUid);
    expect(second.single.newEvents, 0);
    expect(await profileCount(local), profiles);
    final SrsDbStore s = await store(local, uid, 'devA');
    expect((await s.exportAll()).length, events);
    expect(await s.cardsOfNote(noteId), hasLength(1));
  });
}
