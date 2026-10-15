import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 备份合并导入的 SRS 专用步骤（计划铁律 E），走真实的 ATTACH + [BackupMergeEngine.merge]。
///
/// srs_* 表在通用路径登记为跳过（[mergeSkippedDeviceLocalTableNames]），由引擎的
/// SRS 步骤按 `profiles.uid` 归位：同 uid 直接合并；同名且无用户笔记、未发布则采用
/// 备份 uid；否则新建「<原名>（备份）」。不做 ID 重映射，合并两次幂等。
void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late FushiDatabase target;

  setUp(() => target = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => target.close());

  Future<int> insertProfile(FushiDatabase db, String name) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.customStatement(
      'INSERT INTO profiles (name, created_at, updated_at) VALUES (?, ?, ?)',
      <Object>[name, now, now],
    );
    return (await db
            .customSelect(
              'SELECT id FROM profiles WHERE name = ?',
              variables: <Variable<Object>>[Variable<String>(name)],
            )
            .getSingle())
        .read<int>('id');
  }

  Future<String?> uidOfName(FushiDatabase db, String name) async =>
      (await db
              .customSelect(
                'SELECT uid FROM profiles WHERE name = ?',
                variables: <Variable<Object>>[Variable<String>(name)],
              )
              .getSingleOrNull())
          ?.read<String?>('uid');

  Future<String?> ownerOf(String entityId) async =>
      (await target
              .customSelect(
                'SELECT profile_uid FROM srs_entities WHERE id = ?',
                variables: <Variable<Object>>[Variable<String>(entityId)],
              )
              .getSingleOrNull())
          ?.read<String>('profile_uid');

  Future<int> count(String sql) async =>
      (await target.customSelect(sql).getSingle()).read<int>('c');

  Future<SrsDbStore> store(FushiDatabase db, String uid) =>
      SrsDbStore.open(db: db, profileUid: uid, deviceId: 'dev-target');

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  /// 磁盘上建备份库（ATTACH 需要真文件）：一个名为 [name]、带一条笔记的 profile。
  /// 返回 (库路径, profile uid, noteId)。
  Future<(String, String, String)> buildBackup(String name) async {
    final Directory dir = await Directory.systemTemp.createTemp('srs_merge_');
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase src = FushiDatabase(dir.path);
    final int id = await insertProfile(src, name);
    final String uid = await src.profileUidOf(id);
    final SrsDbStore s = await SrsDbStore.open(
      db: src,
      profileUid: uid,
      deviceId: 'dev-src',
    );
    final String noteId = await addNote(s, '雪');
    await src.close();
    return (p.join(dir.path, 'fushi.db'), uid, noteId);
  }

  Future<void> attachAndMerge(String srcPath) async {
    final String safe = srcPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    try {
      await BackupMergeEngine(target).merge();
    } finally {
      await target.customStatement('DETACH DATABASE mergesrc');
    }
  }

  test('同 uid：并进本机已有 profile，卡片缓存随之生成', () async {
    final (String srcPath, String uid, String noteId) = await buildBackup('日语');
    final int localId = await insertProfile(target, '日语');
    await target.adoptProfileUid(localId, uid);

    await attachAndMerge(srcPath);

    expect(await ownerOf(noteId), uid);
    final SrsDbStore s = await store(target, uid);
    expect(
      (await s.note(noteId))!.field(srsLapisFieldId(uid, 'Expression')),
      '雪',
    );
    expect(await s.cardsOfNote(noteId), hasLength(1));
    expect(await uidOfName(target, '日语（备份）'), isNull);
  });

  test('同名、本机无用户笔记且未发布 → 采用备份 uid（含合并时刚按名建出的 profile）', () async {
    final (String srcPath, String uid, String noteId) = await buildBackup('日语');
    // 本机没有「日语」：通用路径先按名建出，SRS 步骤再采用备份 uid。
    await attachAndMerge(srcPath);
    expect(await uidOfName(target, '日语'), uid);
    expect(await ownerOf(noteId), uid);
    expect(await uidOfName(target, '日语（备份）'), isNull);
  });

  test('同名、本机打开过 SRS 但无笔记未发布 → 采用备份 uid，旧 uid 行清空', () async {
    final (String srcPath, String uid, String noteId) = await buildBackup('日语');
    final int localId = await insertProfile(target, '日语');
    final String oldUid = await target.profileUidOf(localId);
    await store(target, oldUid); // 只有内置行 + 本机状态

    await attachAndMerge(srcPath);

    expect(await uidOfName(target, '日语'), uid);
    expect(await ownerOf(noteId), uid);
    expect(
      await count(
        'SELECT COUNT(*) AS c FROM srs_entities '
        "WHERE profile_uid = '$oldUid'",
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) AS c FROM srs_local_state '
        "WHERE profile_uid = '$oldUid'",
      ),
      0,
    );
  });

  test('同名但本机有用户笔记 → 新建「日语（备份）」，本机数据不动', () async {
    final (String srcPath, String uid, String noteId) = await buildBackup('日语');
    final int localId = await insertProfile(target, '日语');
    final String oldUid = await target.profileUidOf(localId);
    final String localNote = await addNote(await store(target, oldUid), '花');

    await attachAndMerge(srcPath);

    expect(await uidOfName(target, '日语'), oldUid);
    expect(await uidOfName(target, '日语（备份）'), uid);
    expect(await ownerOf(localNote), oldUid);
    expect(await ownerOf(noteId), uid);
    expect(await (await store(target, uid)).cardsOfNote(noteId), hasLength(1));
  });

  test('同名但本机发布过批次 → 不改 uid，新建「日语（备份）」', () async {
    final (String srcPath, String uid, _) = await buildBackup('日语');
    final int localId = await insertProfile(target, '日语');
    final String oldUid = await target.profileUidOf(localId);
    final SrsDbStore s = await store(target, oldUid);
    await s.saveSyncState(
      SrsSyncLocalState(writerId: s.writerId, nextBatchNo: 2),
    );

    await attachAndMerge(srcPath);

    expect(await uidOfName(target, '日语'), oldUid);
    expect(await uidOfName(target, '日语（备份）'), uid);
  });

  test('合并两次幂等：profile / 事件 / 卡片数都不变', () async {
    final (String srcPath, String uid, String noteId) = await buildBackup('日语');
    final int localId = await insertProfile(target, '日语');
    final String oldUid = await target.profileUidOf(localId);
    await addNote(await store(target, oldUid), '花');

    await attachAndMerge(srcPath);
    const String counts =
        'SELECT '
        '(SELECT COUNT(*) FROM profiles) * 1000000 + '
        '(SELECT COUNT(*) FROM srs_entities) * 1000 + '
        '(SELECT COUNT(*) FROM srs_field_edits) AS c';
    final int first = await count(counts);
    final int cards = await count('SELECT COUNT(*) AS c FROM srs_cards_cache');

    await attachAndMerge(srcPath);

    expect(await count(counts), first);
    expect(await count('SELECT COUNT(*) AS c FROM srs_cards_cache'), cards);
    expect(await uidOfName(target, '日语（备份）'), uid);
    expect(await uidOfName(target, '日语（备份 2）'), isNull);
    expect(await ownerOf(noteId), uid);
  });
}
