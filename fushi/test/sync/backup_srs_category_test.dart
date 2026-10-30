import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart'
    show DatabaseConnectionUser, QueryRow, Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupCategoryShownInExport, importSelectableCategories;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// `BackupCategory.srs`（复习）：Rust 的 srs.db 快照（zip 条目 `srs.db`）+ `<support>/srs_media/`
/// 媒体目录成为备份类别（docs/specs/2026-10-23-srs-rust-store.md §4）。主库条目不带 SRS；
/// 2026-10-23 之前的老形态备份（SRS 表在主库条目里）恢复 / 合并照样认。部分恢复不带配置档案
/// 时，SRS 按 profile uid 归位，不留孤儿。
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

  Future<int> count(DatabaseConnectionUser db, String sql) async =>
      (await db.customSelect(sql).getSingle()).data['c'] as int;

  Future<bool> hasTable(FushiDatabase db, String table) async =>
      (await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: <Variable<Object>>[Variable<String>(table)],
          )
          .getSingleOrNull()) !=
      null;

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

  /// srs.db 里 profile_uid 对不上主库任何 profiles.uid 的身份记录数（跨两个文件，在 Dart 里比）。
  Future<int> orphanSrsRows(FushiDatabase db, SrsStorage srs) async {
    final Set<String> uids = <String>{
      for (final QueryRow r
          in await db
              .customSelect('SELECT uid FROM profiles WHERE uid IS NOT NULL')
              .get())
        r.read<String>('uid'),
    };
    return (await srs.db
            .customSelect('SELECT profile_uid FROM srs_entities')
            .get())
        .where((QueryRow r) => !uids.contains(r.read<String>('profile_uid')))
        .length;
  }

  Future<String?> ownerOf(SrsStorage srs, String id) async =>
      (await srs.db
              .customSelect(
                'SELECT profile_uid FROM srs_entities WHERE id = ?',
                variables: <Variable<Object>>[Variable<String>(id, srsIdType)],
              )
              .getSingleOrNull())
          ?.read<String>('profile_uid');

  Future<int> noteCount(SrsStorage srs) => count(
    srs.db,
    "SELECT COUNT(*) AS c FROM srs_entities WHERE kind = 'note'",
  );

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  Future<SrsDbStore> storeOn(SrsStorage srs, String uid, String deviceId) =>
      SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: deviceId,
      );

  /// 按 app 的方式（主进程：带一次性搬迁）打开 [dbDir] 下的 srs.db。调用方负责关。
  Future<SrsStorage> openSrsLikeApp(String dbDir, FushiDatabase db) =>
      SrsStorage.open(path: SrsStorage.pathIn(dbDir), legacy: db, inline: true);

  /// 源设备：profile「日语」一条笔记 + 两个媒体文件（另有一个写入中途的 .tmp）。
  /// [legacy] 为真时模拟还没搬迁的设备：SRS 只在主库老表里，本机没有 srs.db。
  Future<
    ({
      FushiDatabase db,
      SrsStorage? srs,
      String dbDir,
      String uid,
      String noteId,
      List<String> media,
    })
  >
  seedSource({bool withSrs = true, bool legacy = false}) async {
    final String dbDir = p.join(src.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    final int pid = await insertProfile(db, '日语');
    final String uid = await db.profileUidOf(pid);
    final SrsStorage srs = await SrsStorage.open(
      path: legacy
          ? p.join(src.path, 'scratch_srs.db')
          : SrsStorage.pathIn(dbDir),
      inline: true,
    );
    final SrsDbStore store = await storeOn(srs, uid, 'dev-src');
    if (!withSrs) {
      // 模块打开过（有内置行）但没有任何用户数据。
      return (
        db: db,
        srs: srs,
        dbDir: dbDir,
        uid: uid,
        noteId: '',
        media: <String>[],
      );
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
    if (legacy) {
      for (final MapEntry<String, String> t in kLegacySrsTableDdl.entries) {
        await db.customStatement(t.value);
        // 只抄老表有的列：srs.db 之后加的列（schema v4 的 media_refs 等）老形态里本来就没有。
        final Set<String> legacyCols = <String>{
          for (final QueryRow c
              in await db.customSelect('PRAGMA table_info(${t.key})').get())
            c.read<String>('name'),
        };
        for (final QueryRow r
            in await srs.db.customSelect('SELECT * FROM ${t.key}').get()) {
          final List<String> cols = <String>[
            for (final String c in r.data.keys)
              if (legacyCols.contains(c)) c,
          ];
          await db.customStatement(
            'INSERT INTO ${t.key} (${cols.join(', ')}) '
            'VALUES (${List<String>.filled(cols.length, '?').join(', ')})',
            <Object?>[for (final String c in cols) r.data[c]],
          );
        }
      }
      await srs.close();
    }
    return (
      db: db,
      srs: legacy ? null : srs,
      dbDir: dbDir,
      uid: uid,
      noteId: noteId,
      media: <String>[a, b],
    );
  }

  BackupService serviceFor(FushiDatabase db, String dbDir, SrsStorage? srs) =>
      BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
        srsStorage: () async => srs,
      );

  /// 导出一份（全部类别），然后关掉源设备的两个库。
  Future<String> exportAll({bool legacy = false}) async {
    final s = await seedSource(legacy: legacy);
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir, s.srs).createBackup(zip);
    await s.srs?.close();
    await s.db.close();
    return zip;
  }

  /// 目标设备：已有一个本机库（覆盖恢复有 bak 可回灌），profile「日语」uid 与源不同。
  Future<String> seedTarget({bool withLocalNote = false}) async {
    final String dbDir = p.join(dst.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      final int pid = await insertProfile(db, '日语');
      final String uid = await db.profileUidOf(pid);
      if (withLocalNote) {
        final SrsStorage srs = await openSrsLikeApp(dbDir, db);
        try {
          await addNote(await storeOn(srs, uid, 'dev-dst'), '花');
        } finally {
          await srs.close();
        }
      }
    } finally {
      await db.close();
    }
    return dbDir;
  }

  /// 在 [dbDir] 上按 app 的方式开两个库跑 [body]，跑完都关。
  Future<void> onTarget(
    String dbDir,
    Future<void> Function(FushiDatabase db, SrsStorage srs) body,
  ) async {
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      final SrsStorage srs = await openSrsLikeApp(dbDir, db);
      try {
        await body(db, srs);
      } finally {
        await srs.close();
      }
    } finally {
      await db.close();
    }
  }

  /// 把 zip 里的条目 [name] 写到 [dir]/[name]。
  String extract(Archive archive, String name, Directory dir) {
    final String out = p.join(dir.path, name);
    File(out).writeAsBytesSync(archive.findFile(name)!.content as List<int>);
    return out;
  }

  test(
    '导出：预览计数 = 笔记 + 媒体；zip 带 srs.db 快照（本机状态已清）与 srs_media，主库条目不带 SRS',
    () async {
      final s = await seedSource();
      final BackupService service = serviceFor(s.db, s.dbDir, s.srs);
      final BackupContentSummary live = await service.summarizeLiveContent();
      expect(live.countFor(BackupCategory.srs), 1 + 2);
      expect(backupCategoryShownInExport(BackupCategory.srs, live), isTrue);

      final String zip = p.join(src.path, 'all.zip');
      final BackupMeta meta = await service.createBackup(zip);
      await s.srs!.close();
      await s.db.close();
      expect(meta.srsNoteCount, 1);

      final Archive archive = await readZip(zip);
      expect(srsMediaEntries(archive).toSet(), <String>{
        for (final String name in s.media) 'srs_media/${s.uid}/$name',
      });

      final Directory ex = Directory(p.join(dst.path, 'ex'))..createSync();
      extract(archive, 'fushi.db', ex);
      final FushiDatabase blob = FushiDatabase(ex.path);
      try {
        expect(await hasTable(blob, 'srs_entities'), isFalse);
        expect(await uidOfName(blob, '日语'), s.uid);
      } finally {
        await blob.close();
      }
      final SrsStorage snap = await SrsStorage.open(
        path: extract(archive, 'srs.db', ex),
        inline: true,
      );
      try {
        expect(await noteCount(snap), 1);
        expect(
          await count(snap.db, 'SELECT COUNT(*) AS c FROM srs_local_state'),
          0,
          reason: '本机状态永不出境',
        );
        expect(
          await count(snap.db, 'SELECT COUNT(*) AS c FROM srs_event_local'),
          0,
        );
      } finally {
        await snap.close();
      }

      final BackupContentSummary viaFile =
          await BackupRestoreService.summarizeBackupFile(zip);
      expect(viaFile.countFor(BackupCategory.srs), 3);
      expect(importSelectableCategories, contains(BackupCategory.srs));
    },
  );

  test('导出取消勾选 srs：无 srs.db / srs_media 条目、meta 记为排除', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'nosrs.zip');
    final BackupMeta meta = await serviceFor(s.db, s.dbDir, s.srs).createBackup(
      zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    await s.srs!.close();
    await s.db.close();
    expect(meta.srsNoteCount, 0);
    expect(meta.excludedCategories, contains('srs'));

    final Archive archive = await readZip(zip);
    expect(srsMediaEntries(archive), isEmpty);
    expect(archive.findFile('srs.db'), isNull);
    expect(
      (await BackupRestoreService.summarizeBackupFile(
        zip,
      )).has(BackupCategory.srs),
      isFalse,
    );
  });

  test('导出：本机还没搬迁（SRS 在主库老表、没有 srs.db）→ 老表随主库条目走，设备本地表清空', () async {
    final s = await seedSource(legacy: true);
    final String zip = p.join(src.path, 'legacy.zip');
    final BackupMeta meta = await serviceFor(
      s.db,
      s.dbDir,
      null,
    ).createBackup(zip);
    await s.db.close();
    expect(meta.srsNoteCount, 1);
    final Archive archive = await readZip(zip);
    expect(archive.findFile('srs.db'), isNull);
    final Directory ex = Directory(p.join(dst.path, 'ex'))..createSync();
    extract(archive, 'fushi.db', ex);
    final FushiDatabase blob = FushiDatabase(ex.path);
    try {
      expect(
        await count(
          blob,
          "SELECT COUNT(*) AS c FROM srs_entities WHERE kind = 'note'",
        ),
        1,
      );
      expect(await count(blob, 'SELECT COUNT(*) AS c FROM srs_local_state'), 0);
    } finally {
      await blob.close();
    }
  });

  test('导出不勾 srs、本机还没搬迁：主库条目里的老 SRS 表整张删掉', () async {
    final s = await seedSource(legacy: true);
    final String zip = p.join(src.path, 'legacy_nosrs.zip');
    await serviceFor(s.db, s.dbDir, null).createBackup(
      zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    await s.db.close();
    final Directory ex = Directory(p.join(dst.path, 'ex'))..createSync();
    extract(await readZip(zip), 'fushi.db', ex);
    final FushiDatabase blob = FushiDatabase(ex.path);
    try {
      expect(await hasTable(blob, 'srs_entities'), isFalse);
    } finally {
      await blob.close();
    }
  });

  test('导出不勾配置档案但勾 srs：只留拥有 SRS 数据的档案行（uid 来自 srs.db）', () async {
    final s = await seedSource();
    await insertProfile(s.db, '无复习');
    final String zip = p.join(src.path, 'noprof.zip');
    await serviceFor(s.db, s.dbDir, s.srs).createBackup(
      zip,
      categories: BackupCategory.values.toSet()
        ..remove(BackupCategory.profiles),
    );
    await s.srs!.close();
    await s.db.close();
    final Directory ex = Directory(p.join(dst.path, 'ex'))..createSync();
    extract(await readZip(zip), 'fushi.db', ex);
    final FushiDatabase blob = FushiDatabase(ex.path);
    try {
      expect(await uidOfName(blob, '日语'), s.uid);
      expect(await uidOfName(blob, '无复习'), isNull);
    } finally {
      await blob.close();
    }
  });

  test('本机没有 SRS 数据：类别不显示、导出不含任何 srs_media 条目', () async {
    final s = await seedSource(withSrs: false);
    final BackupService service = serviceFor(s.db, s.dbDir, s.srs);
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
    await s.srs!.close();
    await s.db.close();
    expect(srsMediaEntries(await readZip(zip)), isEmpty);
    expect(
      (await BackupRestoreService.summarizeBackupFile(
        zip,
      )).has(BackupCategory.srs),
      isFalse,
    );
  });

  for (final bool legacy in <bool>[false, true]) {
    final String shape = legacy ? '老形态备份' : '新形态备份';

    test('$shape 覆盖恢复（勾配置档案 + srs）：本机 srs.db 换成备份的、媒体落到支持目录', () async {
      final String zip = await exportAll(legacy: legacy);
      final String dstDb = await seedTarget(withLocalNote: true);
      final s = (uid: await _uidIn(src), noteId: await _noteIn(src, legacy));

      await BackupRestoreService.restoreBackup(
        dbDirectory: dstDb,
        zipPath: zip,
        importSettings: true,
      );

      final Directory mediaDir = SrsMediaStore.directoryFor(
        Directory(dstDb),
        s.uid,
      );
      expect(Directory(mediaDir.path).listSync(), hasLength(2));
      expect(
        File('${SrsStorage.pathIn(dstDb)}.restore-new').existsSync(),
        isFalse,
        reason: '暂存文件已换进去',
      );
      await onTarget(dstDb, (FushiDatabase db, SrsStorage srs) async {
        expect(await uidOfName(db, '日语'), s.uid, reason: '配置档案来自备份');
        final SrsDbStore store = await storeOn(srs, s.uid, 'dev-dst');
        expect(await store.note(s.noteId), isNotNull);
        expect(await noteCount(srs), 1, reason: '本机原有的笔记随覆盖换掉');
        expect(await orphanSrsRows(db, srs), 0);
        expect(await hasTable(db, 'srs_entities'), isFalse, reason: '老表搬完即删');
      });
    });

    test('$shape 覆盖恢复勾 srs 不勾配置档案：走 SRS 专用合并，无孤儿行', () async {
      final String zip = await exportAll(legacy: legacy);
      final s = (uid: await _uidIn(src), noteId: await _noteIn(src, legacy));
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

      await onTarget(dstDb, (FushiDatabase db, SrsStorage srs) async {
        expect(await orphanSrsRows(db, srs), 0);
        expect(await ownerOf(srs, s.noteId), s.uid);
        // 覆盖语义：本机原有的 SRS 换成备份的 → 同名档案无笔记未发布 → 采用备份 uid。
        expect(await uidOfName(db, '日语'), s.uid);
        final SrsDbStore store = await storeOn(srs, s.uid, 'dev-dst');
        expect(await store.cardsOfNote(s.noteId), hasLength(1));
        expect(await hasTable(db, 'srs_entities'), isFalse);
      });
      final Directory mediaDir = SrsMediaStore.directoryFor(
        Directory(dstDb),
        s.uid,
      );
      expect(Directory(mediaDir.path).listSync(), hasLength(2));
    });

    test('$shape 覆盖恢复不勾 srs：备份的 SRS 与媒体不落地，本机 srs.db 原样保留', () async {
      final String zip = await exportAll(legacy: legacy);
      final String dstDb = await seedTarget(withLocalNote: true);

      await BackupRestoreService.restoreBackup(
        dbDirectory: dstDb,
        zipPath: zip,
        importSettings: true,
        categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
      );
      await onTarget(dstDb, (FushiDatabase db, SrsStorage srs) async {
        expect(await hasTable(db, 'srs_entities'), isFalse);
        expect(await noteCount(srs), 1, reason: '本机那条「花」还在');
        expect(await ownerOf(srs, await _noteIn(src, legacy)), isNull);
      });
      expect(
        SrsMediaStore.mediaRootFor(Directory(dstDb)).existsSync(),
        isFalse,
      );
    });

    test('$shape 合并导入：媒体按文件名取并集、已存在跳过；两次合并幂等', () async {
      final String zip = await exportAll(legacy: legacy);
      final s = (uid: await _uidIn(src), noteId: await _noteIn(src, legacy));
      final String dstDb = await seedTarget();
      // 本机已有同名文件（同名即同内容；这里故意写不同字节，以证明它没被覆盖）。
      final Directory mediaDir = SrsMediaStore.directoryFor(
        Directory(dstDb),
        s.uid,
      )..createSync(recursive: true);
      final List<String> names = <String>[
        for (final FileSystemEntity e in SrsMediaStore.directoryFor(
          Directory(p.join(src.path, 'support')),
          s.uid,
        ).listSync())
          if (!e.path.endsWith('.tmp')) p.basename(e.path),
      ]..sort();
      final File existing = File(p.join(mediaDir.path, names.first))
        ..writeAsStringSync('LOCAL');

      Future<void> mergeOnce() => BackupRestoreService.mergeRestoreBackup(
        dbDirectory: dstDb,
        zipPath: zip,
        categories: BackupCategory.values.toSet(),
      );

      await mergeOnce();
      expect(existing.readAsStringSync(), 'LOCAL', reason: '已存在跳过');
      expect(File(p.join(mediaDir.path, names.last)).existsSync(), isTrue);
      expect(
        File(p.join(dstDb, 'fushi.db.merge-src-srs')).existsSync(),
        isFalse,
        reason: 'srs.db 副本用完即删',
      );

      late int profiles;
      late int events;
      Future<(int, int)> fingerprint(FushiDatabase db, SrsStorage srs) async =>
          (
            await count(db, 'SELECT COUNT(*) AS c FROM profiles'),
            await count(
              srs.db,
              'SELECT (SELECT COUNT(*) FROM srs_entities) * 1000 + '
              '(SELECT COUNT(*) FROM srs_field_edits) AS c',
            ),
          );
      await onTarget(dstDb, (FushiDatabase db, SrsStorage srs) async {
        (profiles, events) = await fingerprint(db, srs);
        expect(await orphanSrsRows(db, srs), 0);
        expect(await noteCount(srs), 1);
      });
      final List<String> filesAfterFirst =
          mediaDir
              .listSync()
              .map((FileSystemEntity e) => p.basename(e.path))
              .toList()
            ..sort();

      await mergeOnce();
      await onTarget(dstDb, (FushiDatabase db, SrsStorage srs) async {
        expect(await fingerprint(db, srs), (profiles, events));
        expect(await uidOfName(db, '日语（备份 2）'), isNull);
      });
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

    test('$shape 合并导入不勾 srs：既不并数据也不拷媒体，也不建 srs.db', () async {
      final String zip = await exportAll(legacy: legacy);
      final String dstDb = await seedTarget();
      await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: dstDb,
        zipPath: zip,
        categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
      );
      expect(File(SrsStorage.pathIn(dstDb)).existsSync(), isFalse);
      expect(
        SrsMediaStore.mediaRootFor(Directory(dstDb)).existsSync(),
        isFalse,
      );
    });
  }

  test('启动恢复：sidecar 记着 srs=replace 且暂存文件还在 → 换进 srs.db（并清掉旧 -wal）', () async {
    final String dstDb = await seedTarget(withLocalNote: true);
    // 暂存一份「备份的」srs.db（与真实流程一样是 Rust 的 VACUUM INTO 快照）：另一个 profile
    // 的一条笔记。
    final String staged = '${SrsStorage.pathIn(dstDb)}.restore-new';
    final SrsStorage other = await SrsStorage.open(
      path: p.join(dst.path, 'other_srs.db'),
      inline: true,
    );
    const String otherUid = '01928c3e-0000-7000-8000-00000000beef';
    final String otherNote = await addNote(
      await storeOn(other, otherUid, 'dev-x'),
      '月',
    );
    other.core.snapshotInto(staged, stripDeviceLocal: true);
    await other.close();
    File('${SrsStorage.pathIn(dstDb)}-wal').writeAsStringSync('stale frames');
    File(p.join(dstDb, 'fushi.db.sync-preserve.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'mode': 'prefs',
        'prefs': <String, String>{},
        'srs': 'replace',
      }),
    );

    await BackupRestoreService.recoverPendingRestore(dstDb);

    expect(File(staged).existsSync(), isFalse);
    expect(File('${SrsStorage.pathIn(dstDb)}-wal').existsSync(), isFalse);
    await onTarget(dstDb, (FushiDatabase db, SrsStorage srs) async {
      expect(await ownerOf(srs, otherNote), otherUid);
      expect(await noteCount(srs), 1, reason: '本机原来的「花」随换文件消失');
    });
    // 重放幂等：再跑一次（sidecar 已删）什么都不动。
    await BackupRestoreService.recoverPendingRestore(dstDb);
    expect(File(SrsStorage.pathIn(dstDb)).existsSync(), isTrue);
  });
}

/// 源设备 profile「日语」的 uid（seedSource 之后读，源库已关）。
Future<String> _uidIn(Directory src) async {
  final FushiDatabase db = FushiDatabase(p.join(src.path, 'support'));
  try {
    return (await db
            .customSelect("SELECT uid FROM profiles WHERE name = '日语'")
            .getSingle())
        .read<String>('uid');
  } finally {
    await db.close();
  }
}

/// 源设备那条笔记的 id：新形态从源 srs.db 读，老形态从源主库老表读。
Future<String> _noteIn(Directory src, bool legacy) async {
  const String sql = "SELECT id FROM srs_entities WHERE kind = 'note'";
  final String dbDir = p.join(src.path, 'support');
  if (legacy) {
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      return (await db.customSelect(sql).getSingle()).read<String>('id');
    } finally {
      await db.close();
    }
  }
  final SrsStorage srs = await SrsStorage.open(
    path: SrsStorage.pathIn(dbDir),
    inline: true,
  );
  try {
    return (await srs.db.customSelect(sql).getSingle()).read<String>('id');
  } finally {
    await srs.close();
  }
}
