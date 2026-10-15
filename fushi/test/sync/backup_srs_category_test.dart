import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupCategoryShownInExport, importSelectableCategories;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// `BackupCategory.srs`（复习）：四张 SRS 数据表 + `<support>/srs_media/` 媒体目录
/// 成为备份类别。此前媒体从不进备份（恢复 / 换设备后卡片图片音频全丢），而部分恢复
/// 不带配置档案时 SRS 行挂在备份那边的 profile uid 上成了孤儿。
void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_srs_src_');
    dst = await Directory.systemTemp.createTemp('bk_srs_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<Archive> readZip(String zipPath) async =>
      // 整包读进内存再解（archive 3.x 惰性读：流关掉后再取 content 会读坏）。
      ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());

  List<String> srsMediaEntries(Archive archive) => <String>[
    for (final ArchiveFile f in archive.files)
      if (f.isFile && f.name.startsWith('srs_media/')) f.name,
  ];

  Future<int> count(FushiDatabase db, String sql) async =>
      (await db.customSelect(sql).getSingle()).data['c'] as int;

  Future<int> insertProfile(FushiDatabase db, String name) async {
    await db.customStatement(
      'INSERT INTO profiles (name, created_at, updated_at) VALUES (?, 1, 1)',
      <Object>[name],
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

  /// SRS 行的 profile_uid 都能对上本机 profiles.uid 时返回 0。
  Future<int> orphanSrsRows(FushiDatabase db) => count(
    db,
    'SELECT COUNT(*) AS c FROM srs_entities WHERE profile_uid NOT IN '
    '(SELECT uid FROM profiles WHERE uid IS NOT NULL)',
  );

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  /// 源设备：profile「日语」一条笔记 + 两个媒体文件（另有一个写入中途的 .tmp）。
  Future<
    ({
      FushiDatabase db,
      String dbDir,
      String uid,
      String noteId,
      List<String> media,
    })
  >
  seedSource({bool withSrs = true}) async {
    final String dbDir = p.join(src.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    final int pid = await insertProfile(db, '日语');
    final String uid = await db.profileUidOf(pid);
    final SrsDbStore store = await SrsDbStore.open(
      db: db,
      profileUid: uid,
      deviceId: 'dev-src',
    );
    if (!withSrs) {
      // 模块打开过（有内置行）但没有任何用户数据。
      return (db: db, dbDir: dbDir, uid: uid, noteId: '', media: <String>[]);
    }
    final String noteId = await addNote(store, '雪');
    final SrsMediaStore media = SrsMediaStore(
      SrsMediaStore.directoryFor(Directory(dbDir), uid),
    );
    final String a = await media.store(
      'a.png',
      Uint8List.fromList(utf8.encode('PNG-A')),
    );
    final String b = await media.store(
      'b.mp3',
      Uint8List.fromList(utf8.encode('MP3-B')),
    );
    File(p.join(media.root.path, '$a.123.tmp')).writeAsStringSync('half');
    return (
      db: db,
      dbDir: dbDir,
      uid: uid,
      noteId: noteId,
      media: <String>[a, b],
    );
  }

  BackupService serviceFor(FushiDatabase db, String dbDir) =>
      BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');

  /// 目标设备：已有一个本机库（覆盖恢复有 bak 可回灌），profile「日语」uid 与源不同。
  Future<String> seedTarget({bool withLocalNote = false}) async {
    final String dbDir = p.join(dst.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      final int pid = await insertProfile(db, '日语');
      final String uid = await db.profileUidOf(pid);
      if (withLocalNote) {
        await addNote(
          await SrsDbStore.open(db: db, profileUid: uid, deviceId: 'dev-dst'),
          '花',
        );
      }
    } finally {
      await db.close();
    }
    return dbDir;
  }

  test('导出：预览计数 = 笔记 + 媒体，zip 带四表数据与 srs_media 文件（跳过 .tmp）', () async {
    final s = await seedSource();
    final BackupService service = serviceFor(s.db, s.dbDir);
    final BackupContentSummary live = await service.summarizeLiveContent();
    expect(live.countFor(BackupCategory.srs), 1 + 2);
    expect(backupCategoryShownInExport(BackupCategory.srs, live), isTrue);

    final String zip = p.join(src.path, 'all.zip');
    final BackupMeta meta = await service.createBackup(zip);
    await s.db.close();
    expect(meta.srsNoteCount, 1);

    final Archive archive = await readZip(zip);
    expect(srsMediaEntries(archive).toSet(), <String>{
      for (final String name in s.media) 'srs_media/${s.uid}/$name',
    });

    final Directory ex = Directory(p.join(dst.path, 'ex'))..createSync();
    File(
      p.join(ex.path, 'fushi.db'),
    ).writeAsBytesSync(archive.findFile('fushi.db')!.content as List<int>);
    final FushiDatabase blob = FushiDatabase(ex.path);
    try {
      expect(
        await count(
          blob,
          "SELECT COUNT(*) AS c FROM srs_entities WHERE kind = 'note'",
        ),
        1,
      );
      expect(
        await count(blob, 'SELECT COUNT(*) AS c FROM srs_local_state'),
        0,
        reason: '本机状态永不出境',
      );
    } finally {
      await blob.close();
    }

    final BackupContentSummary viaFile =
        await BackupRestoreService.summarizeBackupFile(zip);
    expect(viaFile.countFor(BackupCategory.srs), 3);
    expect(importSelectableCategories, contains(BackupCategory.srs));
  });

  test('导出取消勾选 srs：无 srs_media 条目、四张数据表剥空、meta 记为排除', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'nosrs.zip');
    final BackupMeta meta = await serviceFor(s.db, s.dbDir).createBackup(
      zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    await s.db.close();
    expect(meta.srsNoteCount, 0);
    expect(meta.excludedCategories, contains('srs'));

    final Archive archive = await readZip(zip);
    expect(srsMediaEntries(archive), isEmpty);
    final Directory ex = Directory(p.join(dst.path, 'ex'))..createSync();
    File(
      p.join(ex.path, 'fushi.db'),
    ).writeAsBytesSync(archive.findFile('fushi.db')!.content as List<int>);
    final FushiDatabase blob = FushiDatabase(ex.path);
    try {
      expect(await count(blob, 'SELECT COUNT(*) AS c FROM srs_entities'), 0);
    } finally {
      await blob.close();
    }
    expect(
      (await BackupRestoreService.summarizeBackupFile(
        zip,
      )).has(BackupCategory.srs),
      isFalse,
    );
  });

  test('本机没有 SRS 数据：类别不显示、导出不含任何 srs_media 条目', () async {
    final s = await seedSource(withSrs: false);
    final BackupService service = serviceFor(s.db, s.dbDir);
    final BackupContentSummary live = await service.summarizeLiveContent();
    expect(live.has(BackupCategory.srs), isFalse);
    expect(backupCategoryShownInExport(BackupCategory.srs, live), isFalse);
    expect(
      backupCategoryShownInExport(BackupCategory.profiles, live),
      isTrue,
      reason: '只隐藏复习这一项',
    );
    final String zip = p.join(src.path, 'plain.zip');
    await service.createBackup(zip);
    await s.db.close();
    expect(srsMediaEntries(await readZip(zip)), isEmpty);
    expect(
      (await BackupRestoreService.summarizeBackupFile(
        zip,
      )).has(BackupCategory.srs),
      isFalse,
    );
  });

  test('覆盖恢复（勾配置档案 + srs）：表原样覆盖、媒体落到支持目录', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir).createBackup(zip);
    await s.db.close();
    final String dstDb = await seedTarget();

    await BackupRestoreService.restoreBackup(
      dbDirectory: dstDb,
      zipPath: zip,
      importSettings: true,
    );

    final Directory mediaDir = SrsMediaStore.directoryFor(
      Directory(dstDb),
      s.uid,
    );
    for (final String name in s.media) {
      expect(File(p.join(mediaDir.path, name)).existsSync(), isTrue);
    }
    expect(
      File(p.join(mediaDir.path, '${s.media.first}.123.tmp')).existsSync(),
      isFalse,
    );
    final FushiDatabase db = FushiDatabase(dstDb);
    try {
      expect(await uidOfName(db, '日语'), s.uid, reason: '配置档案来自备份');
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        profileUid: s.uid,
        deviceId: 'dev-dst',
      );
      expect(await store.note(s.noteId), isNotNull);
      expect(await orphanSrsRows(db), 0);
    } finally {
      await db.close();
    }
  });

  test('覆盖恢复勾 srs 不勾配置档案：走 SRS 专用合并，无孤儿行', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir).createBackup(zip);
    await s.db.close();
    final String dstDb = await seedTarget(withLocalNote: true);
    final FushiDatabase before = FushiDatabase(dstDb);
    final String? localUid = await uidOfName(before, '日语');
    await before.close();
    expect(localUid, isNot(s.uid), reason: '前提：本机档案与备份 uid 不同');

    // importSettings=false：本机设置与配置档案从 bak 回灌（确认框默认）。
    await BackupRestoreService.restoreBackup(
      dbDirectory: dstDb,
      zipPath: zip,
      importSettings: false,
    );

    final FushiDatabase db = FushiDatabase(dstDb);
    try {
      expect(await orphanSrsRows(db), 0, reason: '原样覆盖会把 SRS 行挂在本机不存在的 uid 上');
      final String? owner =
          (await db
                  .customSelect(
                    'SELECT profile_uid FROM srs_entities WHERE id = ?',
                    variables: <Variable<Object>>[Variable<String>(s.noteId)],
                  )
                  .getSingleOrNull())
              ?.read<String>('profile_uid');
      expect(owner, s.uid);
      // 本机同名档案的 SRS 已随覆盖清空（无笔记、未发布）→ 采用备份 uid。
      expect(await uidOfName(db, '日语'), s.uid);
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        profileUid: s.uid,
        deviceId: 'dev-dst',
      );
      expect(await store.cardsOfNote(s.noteId), hasLength(1));
    } finally {
      await db.close();
    }
    final Directory mediaDir = SrsMediaStore.directoryFor(
      Directory(dstDb),
      s.uid,
    );
    for (final String name in s.media) {
      expect(File(p.join(mediaDir.path, name)).existsSync(), isTrue);
    }
  });

  test('覆盖恢复不勾 srs：备份的 SRS 数据与媒体都不落地', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir).createBackup(zip);
    await s.db.close();
    final String dstDb = await seedTarget();

    await BackupRestoreService.restoreBackup(
      dbDirectory: dstDb,
      zipPath: zip,
      importSettings: true,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    final FushiDatabase db = FushiDatabase(dstDb);
    try {
      expect(
        await count(
          db,
          "SELECT COUNT(*) AS c FROM srs_entities WHERE kind = 'note'",
        ),
        0,
      );
    } finally {
      await db.close();
    }
    expect(SrsMediaStore.mediaRootFor(Directory(dstDb)).existsSync(), isFalse);
  });

  test('合并导入：媒体按文件名取并集、已存在跳过；两次合并幂等', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir).createBackup(zip);
    await s.db.close();
    final String dstDb = await seedTarget();
    // 本机已有同名文件（同名即同内容；这里故意写不同字节，以证明它没被覆盖）。
    final Directory mediaDir = SrsMediaStore.directoryFor(
      Directory(dstDb),
      s.uid,
    )..createSync(recursive: true);
    final File existing = File(p.join(mediaDir.path, s.media.first))
      ..writeAsStringSync('LOCAL');

    Future<void> mergeOnce() => BackupRestoreService.mergeRestoreBackup(
      dbDirectory: dstDb,
      zipPath: zip,
      categories: BackupCategory.values.toSet(),
    );

    await mergeOnce();
    expect(existing.readAsStringSync(), 'LOCAL', reason: '已存在跳过');
    expect(
      File(p.join(mediaDir.path, s.media.last)).readAsStringSync(),
      'MP3-B',
      reason: '本机没有的解出来',
    );

    const String fingerprint =
        'SELECT '
        '(SELECT COUNT(*) FROM profiles) * 1000000 + '
        '(SELECT COUNT(*) FROM srs_entities) * 1000 + '
        '(SELECT COUNT(*) FROM srs_field_edits) AS c';
    FushiDatabase db = FushiDatabase(dstDb);
    final int first;
    try {
      first = await count(db, fingerprint);
      expect(await orphanSrsRows(db), 0);
      expect(
        await count(
          db,
          "SELECT COUNT(*) AS c FROM srs_entities WHERE kind = 'note'",
        ),
        1,
      );
    } finally {
      await db.close();
    }
    final List<String> filesAfterFirst =
        mediaDir
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort();

    await mergeOnce();
    db = FushiDatabase(dstDb);
    try {
      expect(await count(db, fingerprint), first);
      expect(await uidOfName(db, '日语（备份 2）'), isNull);
    } finally {
      await db.close();
    }
    expect(
      mediaDir
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toList()
        ..sort(),
      filesAfterFirst,
    );
    expect(existing.readAsStringSync(), 'LOCAL');
  });

  test('合并导入不勾 srs：既不并数据也不拷媒体', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir).createBackup(zip);
    await s.db.close();
    final String dstDb = await seedTarget();
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: dstDb,
      zipPath: zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    final FushiDatabase db = FushiDatabase(dstDb);
    try {
      expect(
        await count(
          db,
          "SELECT COUNT(*) AS c FROM srs_entities WHERE kind = 'note'",
        ),
        0,
      );
    } finally {
      await db.close();
    }
    expect(SrsMediaStore.mediaRootFor(Directory(dstDb)).existsSync(), isFalse);
  });
}
