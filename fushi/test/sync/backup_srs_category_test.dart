import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart'
    show DatabaseConnectionUser, QueryRow, Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupCategoryShownInExport, importSelectableCategories;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_bundle.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import '../srs/srs_test_support.dart' show SrsTestEngine;
import 'temp_dir_cleanup.dart';

/// `BackupCategory.srs`（复习）在新代（协议 4，G11-4）上的整包备份 / 还原：
///
/// - 导出：`srs/manifest.json` + 每个集合一条 `srs/<n>.bin`（内核 FSRS4EXP 流），不再有 `srs.db` 条目；清单不带 `magic`。
/// - 覆盖还原：暂存空新代库落库后换上；本机原来的 `srs4.db` 改名留作回退（逐字节原样）；复习数据逐表与源一致。
/// - 合并还原：经内核 `import` 并入，身份变更（另一个复习库 / 新盐）没确认就不落；同一份合并两次幂等。
/// - 旧形态：协议 3 的 `srs.db` 条目、SRS 表在主库条目里的 v1 事件备份，还原后卡片 / 笔记 / 日志条数与源一致。
/// - 失败的还原（坏流 / 清单来自更新版本 / 本机复习库还没迁移）本机逐字节不变。
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
      ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());

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

  Future<String?> uidOfName(DatabaseConnectionUser db, String name) async =>
      (await db
              .customSelect(
                'SELECT uid FROM profiles WHERE name = ?',
                variables: <Variable<Object>>[Variable<String>(name)],
              )
              .getSingleOrNull())
          ?.read<String?>('uid');

  Future<List<String>> profileNames(
    DatabaseConnectionUser db,
  ) async => <String>[
    for (final QueryRow r
        in await db.customSelect('SELECT name FROM profiles ORDER BY id').get())
      r.read<String>('name'),
  ];

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  /// [core] 里 [uid] 的复习数据（内核读命令 `events`：身份记录 / 修改记录 / 复习日志 / 看不懂的事件），逐表排好序。
  /// [withProfile] 为假时去掉各行里的 profile uid（备份落到另一个 uid 的 profile 上时比内容）。
  Future<Map<String, List<String>>> tables(
    SrsCore core,
    String uid, {
    bool withProfile = true,
  }) async {
    final Map<String, SrsColumns> t = (await srsRead(
      core,
      uid,
      'events',
      const <String, Object?>{'ordered': true},
    )).tables;
    String strip(String json) {
      if (withProfile) return json;
      final Map<String, Object?> m =
          (jsonDecode(json) as Map).cast<String, Object?>()..remove('p');
      return jsonEncode(m);
    }

    final SrsColumns e = t['entities']!;
    return <String, List<String>>{
      'entities': <String>[
        for (int i = 0; i < e.rows; i++)
          '${e.strings('id')[i]}|${e.strings('kind')[i]}|'
              '${e.strings('payload_json')[i]}',
      ]..sort(),
      for (final String name in <String>['edits', 'logs', 'unknown'])
        name: <String>[
          for (final String j in t[name]!.strings('json').toList()) strip(j),
        ]..sort(),
    };
  }

  int count(Map<String, List<String>> t, String table) => t[table]!.length;

  /// 源设备：profile「日语」两条笔记、一次作答 + 两个媒体文件（另有一个写入中途的 .tmp）。
  /// [legacy]：模拟 2026-10-23 之前的设备——SRS 只在主库老表里（v1 事件），没有复习库。
  Future<
    ({
      FushiDatabase db,
      SrsStorage? srs,
      String dbDir,
      String uid,
      Map<String, List<String>> tables,
      List<String> media,
    })
  >
  seedSource({bool legacy = false}) async {
    final String dbDir = p.join(src.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    final int pid = await insertProfile(db, '日语');
    final String uid = await db.profileUidOf(pid);
    final String libDir = legacy ? p.join(src.path, 'scratch_lib') : dbDir;
    Directory(libDir).createSync(recursive: true);
    final SrsStorage srs = await SrsStorage.open(directory: libDir);
    final SrsDbStore store = await SrsDbStore.open(
      core: srs.core,
      profileUid: uid,
      deviceId: 'dev-src',
      engine: const SrsTestEngine(),
    );
    final String n1 = await addNote(store, '雪');
    await addNote(store, '花');
    final String card = (await store.cardsOfNote(n1)).first.id;
    await store.answer(card, 3);
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
    final Map<String, List<String>> before = await tables(srs.core, uid);
    if (legacy) {
      await _writeLegacyTables(
        db,
        await srsEventsOf(srs.core, uid),
        <String, String>{
          for (final SrsCardCacheRow c in await store.cardsOfNote(n1)) c.id: n1,
        },
      );
      await srs.close();
    }
    return (
      db: db,
      srs: legacy ? null : srs,
      dbDir: dbDir,
      uid: uid,
      tables: before,
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

  /// 导出一份（全部类别），关掉源设备的库。回 zip 与源的复习数据表。
  Future<({String zip, String uid, Map<String, List<String>> tables})>
  exportAll({bool legacy = false}) async {
    final s = await seedSource(legacy: legacy);
    final String zip = p.join(src.path, 'all.zip');
    await serviceFor(s.db, s.dbDir, s.srs).createBackup(zip);
    await s.srs?.close();
    await s.db.close();
    return (zip: zip, uid: s.uid, tables: s.tables);
  }

  /// 目标设备：已有本机库（覆盖恢复有 bak 可回灌），profile「日语」uid 与源不同；[withLocalNote] 时它在本机复习库里
  /// 有一条自己的笔记（另一个复习库）。
  Future<String> seedTarget({bool withLocalNote = false}) async {
    final String dbDir = p.join(dst.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      final int pid = await insertProfile(db, '日语');
      final String uid = await db.profileUidOf(pid);
      if (withLocalNote) {
        final SrsStorage srs = await SrsStorage.open(directory: dbDir);
        try {
          await addNote(
            await SrsDbStore.open(
              core: srs.core,
              profileUid: uid,
              deviceId: 'dev-dst',
            ),
            '月',
          );
        } finally {
          await srs.close();
        }
      }
    } finally {
      await db.close();
    }
    return dbDir;
  }

  /// 在 [dbDir] 上开主库与复习库跑 [body]，跑完都关。
  Future<T> onTarget<T>(
    String dbDir,
    Future<T> Function(FushiDatabase db, SrsStorage srs) body,
  ) async {
    final FushiDatabase db = FushiDatabase(dbDir);
    try {
      final SrsStorage srs = await SrsStorage.open(directory: dbDir);
      try {
        return await body(db, srs);
      } finally {
        await srs.close();
      }
    } finally {
      await db.close();
    }
  }

  /// 目录里每个文件 → 字节（不含 SQLite 的 -shm：开关库会重建它）。
  Map<String, List<int>> filesOf(String dir) => <String, List<int>>{
    for (final FileSystemEntity f in Directory(dir).listSync(recursive: true))
      if (f is File && !f.path.endsWith('-shm'))
        p.relative(f.path, from: dir): f.readAsBytesSync(),
  };

  /// 把 zip [from] 改写成 [to]：去掉名字满足 [drop] 的条目，加上 [add]。
  Future<void> rewriteZip(
    String from,
    String to, {
    required bool Function(String name) drop,
    Map<String, List<int>> add = const <String, List<int>>{},
  }) async {
    final Archive inArc = await readZip(from);
    final Archive out = Archive();
    for (final ArchiveFile f in inArc.files) {
      if (!f.isFile || drop(f.name)) continue;
      final List<int> bytes = f.content as List<int>;
      out.addFile(ArchiveFile(f.name, bytes.length, bytes));
    }
    for (final MapEntry<String, List<int>> e in add.entries) {
      out.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    File(to).writeAsBytesSync(ZipEncoder().encode(out)!);
  }

  test(
    '导出：zip 带 srs/manifest.json 与每个集合一条流、srs_media，不再带 srs.db；主库条目不带 SRS',
    () async {
      final s = await seedSource();
      final BackupService service = serviceFor(s.db, s.dbDir, s.srs);
      final BackupContentSummary live = await service.summarizeLiveContent();
      expect(live.countFor(BackupCategory.srs), 2 + 2);
      expect(backupCategoryShownInExport(BackupCategory.srs, live), isTrue);
      final String zip = p.join(src.path, 'all.zip');
      final BackupMeta meta = await service.createBackup(zip);
      await s.srs!.close();
      await s.db.close();
      expect(meta.srsNoteCount, 2);

      final Archive archive = await readZip(zip);
      final Set<String> names = <String>{
        for (final ArchiveFile f in archive.files)
          if (f.isFile) f.name,
      };
      expect(names, contains(kSrsBackupManifestEntry));
      expect(names, contains(srsBackupStreamEntry(0)));
      expect(names, isNot(contains('srs.db')));
      expect(
        names.where((String n) => n.startsWith('srs_media/')).toSet(),
        <String>{for (final String m in s.media) 'srs_media/${s.uid}/$m'},
      );
      final Map<String, Object?> manifest =
          (jsonDecode(
                    utf8.decode(
                      archive.findFile(kSrsBackupManifestEntry)!.content
                          as List<int>,
                    ),
                  )
                  as Map)
              .cast<String, Object?>();
      expect(manifest.containsKey('magic'), isFalse);
      expect(manifest['v'], 2);
      expect(manifest['gen'], 4);
      final SrsBackupBundleManifest parsed = SrsBackupBundleManifest.parse(
        archive.findFile(kSrsBackupManifestEntry)!.content as List<int>,
      );
      expect(parsed.units, hasLength(1));
      expect(parsed.units.single.profiles.single.uid, s.uid);
      expect(parsed.units.single.profiles.single.name, '日语');

      final BackupContentSummary viaFile =
          await BackupRestoreService.summarizeBackupFile(zip);
      expect(viaFile.countFor(BackupCategory.srs), 4);
      expect(importSelectableCategories, contains(BackupCategory.srs));
    },
  );

  test('导出取消勾选 srs：没有 srs/ 与 srs_media 条目、meta 记为排除', () async {
    final s = await seedSource();
    final String zip = p.join(src.path, 'no_srs.zip');
    await serviceFor(s.db, s.dbDir, s.srs).createBackup(
      zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    await s.srs!.close();
    await s.db.close();
    final Archive archive = await readZip(zip);
    expect(
      archive.files.where(
        (ArchiveFile f) =>
            f.name.startsWith('srs/') ||
            f.name.startsWith('srs_media/') ||
            f.name == 'srs.db',
      ),
      isEmpty,
    );
    final BackupMeta? meta = BackupMeta.tryParse(
      utf8.decode(archive.findFile('backup_meta.json')!.content as List<int>),
    );
    expect(meta?.excludedCategories, contains(BackupCategory.srs.name));
  });

  test('覆盖还原（档案来自备份）：复习数据逐表与源一致；本机原来的 srs4.db 改名留作回退、逐字节原样', () async {
    final e = await exportAll();
    final String dbDir = await seedTarget(withLocalNote: true);
    final List<int> before = File(
      SrsStorage.gen4PathIn(dbDir),
    ).readAsBytesSync();
    await BackupRestoreService.restoreBackup(
      dbDirectory: dbDir,
      zipPath: e.zip,
    );
    final List<File> rollbacks = <File>[
      for (final FileSystemEntity f in Directory(dbDir).listSync())
        if (f is File && p.basename(f.path).startsWith('srs4.db.pre-restore-'))
          f,
    ];
    expect(rollbacks, hasLength(1));
    expect(rollbacks.single.readAsBytesSync(), orderedEquals(before));
    expect(
      Directory(p.join(dbDir, 'srs-restore-staged')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(dbDir, 'fushi.db.sync-preserve.json')).existsSync(),
      isFalse,
    );
    await onTarget(dbDir, (FushiDatabase db, SrsStorage srs) async {
      expect(await uidOfName(db, '日语'), e.uid);
      expect(await tables(srs.core, e.uid), e.tables);
    });
    expect(
      File(
        p.join(SrsMediaStore.mediaRootFor(Directory(dbDir)).path, e.uid),
      ).parent.existsSync(),
      isTrue,
    );
  });

  test('覆盖还原（保留本机档案）：落到同名的本机 profile 上，内容与源一致，不留孤儿', () async {
    final e = await exportAll();
    final String dbDir = await seedTarget(withLocalNote: true);
    final String localUid = (await onTarget(
      dbDir,
      (FushiDatabase db, SrsStorage _) async => (await uidOfName(db, '日语'))!,
    ));
    await BackupRestoreService.restoreBackup(
      dbDirectory: dbDir,
      zipPath: e.zip,
      importSettings: false,
    );
    await onTarget(dbDir, (FushiDatabase db, SrsStorage srs) async {
      expect(await profileNames(db), <String>['日语']);
      expect(await uidOfName(db, '日语'), localUid);
      final Map<String, List<String>> got = await tables(
        srs.core,
        localUid,
        withProfile: false,
      );
      expect(count(got, 'logs'), count(e.tables, 'logs'));
      expect(count(got, 'edits'), count(e.tables, 'edits'));
      expect(
        got['entities']!.where((String r) => r.contains('|note|')).length,
        e.tables['entities']!.where((String r) => r.contains('|note|')).length,
      );
    });
  });

  test('覆盖还原不勾 srs：本机复习库逐字节原样，备份的媒体不落地', () async {
    final e = await exportAll();
    final String dbDir = await seedTarget(withLocalNote: true);
    final List<int> before = File(
      SrsStorage.gen4PathIn(dbDir),
    ).readAsBytesSync();
    await BackupRestoreService.restoreBackup(
      dbDirectory: dbDir,
      zipPath: e.zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    expect(
      File(SrsStorage.gen4PathIn(dbDir)).readAsBytesSync(),
      orderedEquals(before),
    );
    expect(
      Directory(
        p.join(SrsMediaStore.mediaRootFor(Directory(dbDir)).path, e.uid),
      ).existsSync(),
      isFalse,
    );
  });

  group('失败的还原：本机逐字节不变', () {
    Future<void> expectUntouched(
      String zip,
      Matcher error, {
      bool merge = false,
    }) async {
      final String dbDir = await seedTarget(withLocalNote: true);
      final Map<String, List<int>> before = filesOf(dbDir);
      await expectLater(
        merge
            ? BackupRestoreService.mergeRestoreBackup(
                dbDirectory: dbDir,
                zipPath: zip,
                srsConfirmed: true,
              )
            : BackupRestoreService.restoreBackup(
                dbDirectory: dbDir,
                zipPath: zip,
              ),
        error,
      );
      final Map<String, List<int>> after = filesOf(dbDir);
      expect(after.keys.toSet(), before.keys.toSet());
      for (final String k in before.keys) {
        expect(after[k], orderedEquals(before[k]!), reason: k);
      }
    }

    test('坏的操作流：暂存库落库失败，什么都没换', () async {
      final e = await exportAll();
      final String bad = p.join(src.path, 'bad.zip');
      await rewriteZip(
        e.zip,
        bad,
        drop: (String n) => n == srsBackupStreamEntry(0),
        add: <String, List<int>>{
          srsBackupStreamEntry(0): utf8.encode('FSRS4EXP but garbage'),
        },
      );
      await expectUntouched(bad, throwsA(anything));
    });

    test('清单来自更新的版本：覆盖与合并都在动任何文件之前拒绝', () async {
      final e = await exportAll();
      final String newer = p.join(src.path, 'newer.zip');
      await rewriteZip(
        e.zip,
        newer,
        drop: (String n) => n == kSrsBackupManifestEntry,
        add: <String, List<int>>{
          kSrsBackupManifestEntry: utf8.encode(
            jsonEncode(<String, Object?>{
              'v': 3,
              'gen': 5,
              'collections': <Object?>[],
            }),
          ),
        },
      );
      await expectUntouched(newer, throwsA(isA<SrsBackupTooNewException>()));
      await cleanupTempDir(dst);
      dst.createSync(recursive: true);
      await expectUntouched(
        newer,
        throwsA(isA<SrsBackupTooNewException>()),
        merge: true,
      );
    });
  });

  test('本机复习库还没迁移（只有协议 3 的 srs.db）：还原明确拒绝，srs.db 逐字节原样', () async {
    final e = await exportAll();
    final String p3 = await _protocol3LibraryFrom(src, e);
    final String dbDir = p.join(dst.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    await insertProfile(db, '日语');
    await db.close();
    File(p3).copySync(SrsStorage.legacyPathIn(dbDir));
    final List<int> before = File(
      SrsStorage.legacyPathIn(dbDir),
    ).readAsBytesSync();
    await expectLater(
      BackupRestoreService.restoreBackup(dbDirectory: dbDir, zipPath: e.zip),
      throwsA(isA<SrsRestoreBlockedException>()),
    );
    expect(
      File(SrsStorage.legacyPathIn(dbDir)).readAsBytesSync(),
      orderedEquals(before),
    );
    expect(File(SrsStorage.gen4PathIn(dbDir)).existsSync(), isFalse);
  });

  test('本机还没迁移：合并只在备份真带复习数据时拒绝（先于改主库）；勾着「复习」但备份里没有复习数据照常合并', () async {
    final e = await exportAll();
    final String p3 = await _protocol3LibraryFrom(src, e);
    final String noSrs = p.join(src.path, 'no_srs_data.zip');
    await rewriteZip(
      e.zip,
      noSrs,
      drop: (String n) => n.startsWith(kSrsBackupPrefix),
    );
    final String dbDir = p.join(dst.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase(dbDir);
    await insertProfile(db, '日语');
    await db.close();
    File(p3).copySync(SrsStorage.legacyPathIn(dbDir));
    final Map<String, List<int>> before = filesOf(dbDir);

    await expectLater(
      BackupRestoreService.mergeRestoreBackup(
        dbDirectory: dbDir,
        zipPath: e.zip,
        srsConfirmed: true,
      ),
      throwsA(isA<SrsRestoreBlockedException>()),
    );
    // 代际状态探测（`SrsGen4Migration.status`）自己会留下协调锁与旧库的 -wal（不在本模块，原有行为）；除此之外没有
    // 新文件（没有合并临时库、没有 pre-merge 快照、没有 srs4.db），原有文件逐字节不变。
    expect(
      filesOf(dbDir).keys.toSet().difference(before.keys.toSet()),
      everyElement(isIn(<String>{'srs.db-wal', 'srs.gen.lock'})),
    );
    for (final MapEntry<String, List<int>> f in before.entries) {
      expect(filesOf(dbDir)[f.key], orderedEquals(f.value), reason: f.key);
    }

    final List<SrsBackupMergeResult> r =
        await BackupRestoreService.mergeRestoreBackup(
          dbDirectory: dbDir,
          zipPath: noSrs,
          srsConfirmed: true,
        );
    expect(r, isEmpty);
    expect(
      File(SrsStorage.legacyPathIn(dbDir)).readAsBytesSync(),
      orderedEquals(before[p.basename(SrsStorage.legacyPathIn(dbDir))]!),
    );
    expect(File(SrsStorage.gen4PathIn(dbDir)).existsSync(), isFalse);
  });

  group('合并还原', () {
    test('没确认：另一个复习库的数据不落、不建「（备份）」profile；确认后落下，再合并一次什么都不变（幂等）', () async {
      final e = await exportAll();
      final String dbDir = await seedTarget(withLocalNote: true);
      final String localUid = await onTarget(
        dbDir,
        (FushiDatabase db, SrsStorage _) async => (await uidOfName(db, '日语'))!,
      );
      final Map<String, List<String>> localBefore = await onTarget(
        dbDir,
        (FushiDatabase _, SrsStorage srs) => tables(srs.core, localUid),
      );

      final List<SrsBackupMergeResult> declined =
          await BackupRestoreService.mergeRestoreBackup(
            dbDirectory: dbDir,
            zipPath: e.zip,
          );
      expect(declined.single.action, SrsBackupMergeAction.declined);
      await onTarget(dbDir, (FushiDatabase db, SrsStorage srs) async {
        expect(await profileNames(db), <String>['日语']);
        expect(await tables(srs.core, localUid), localBefore);
      });

      final List<SrsBackupMergeResult> first =
          await BackupRestoreService.mergeRestoreBackup(
            dbDirectory: dbDir,
            zipPath: e.zip,
            srsConfirmed: true,
          );
      expect(first.single.action, SrsBackupMergeAction.createdProfile);
      expect(first.single.profileUid, e.uid);
      expect(first.single.newEvents, greaterThan(0));
      final Map<String, List<String>> merged = await onTarget(dbDir, (
        FushiDatabase db,
        SrsStorage srs,
      ) async {
        expect(await profileNames(db), <String>['日语', '日语（备份）']);
        expect(await tables(srs.core, localUid), localBefore);
        return tables(srs.core, e.uid);
      });
      expect(merged, e.tables);

      final List<SrsBackupMergeResult> again =
          await BackupRestoreService.mergeRestoreBackup(
            dbDirectory: dbDir,
            zipPath: e.zip,
            srsConfirmed: true,
          );
      expect(again.single.action, SrsBackupMergeAction.sameUid);
      expect(again.single.newEvents, 0);
      await onTarget(dbDir, (FushiDatabase db, SrsStorage srs) async {
        expect(await profileNames(db), <String>['日语', '日语（备份）']);
        expect(await tables(srs.core, e.uid), merged);
      });
    });

    test('合并不勾 srs：既不并数据也不拷媒体，也不建复习库', () async {
      final e = await exportAll();
      final String dbDir = await seedTarget();
      final List<SrsBackupMergeResult> r =
          await BackupRestoreService.mergeRestoreBackup(
            dbDirectory: dbDir,
            zipPath: e.zip,
            categories: BackupCategory.values.toSet()
              ..remove(BackupCategory.srs),
            srsConfirmed: true,
          );
      expect(r, isEmpty);
      expect(File(SrsStorage.gen4PathIn(dbDir)).existsSync(), isFalse);
      expect(
        Directory(
          p.join(SrsMediaStore.mediaRootFor(Directory(dbDir)).path, e.uid),
        ).existsSync(),
        isFalse,
      );
    });
  });

  group('旧形态备份：卡片 / 笔记 / 日志条数与源一致', () {
    test('2026-10-23 之前（SRS 表在主库条目里，v1 事件）：覆盖还原', () async {
      final e = await exportAll(legacy: true);
      final Archive archive = await readZip(e.zip);
      expect(archive.findFile(kSrsBackupManifestEntry), isNull);
      final String dbDir = await seedTarget();
      await BackupRestoreService.restoreBackup(
        dbDirectory: dbDir,
        zipPath: e.zip,
      );
      await onTarget(dbDir, (FushiDatabase db, SrsStorage srs) async {
        expect(await _hasLegacyTables(db), isFalse);
        final Map<String, List<String>> got = await tables(srs.core, e.uid);
        expect(count(got, 'logs'), count(e.tables, 'logs'));
        expect(_notes(got), _notes(e.tables));
        expect(_cards(got), _cards(e.tables));
      });
    });

    test('协议 3 的 srs.db 条目（2026-10-23 起）：合并还原两次，第二次不重复', () async {
      final e = await exportAll();
      final String p3 = await _protocol3LibraryFrom(src, e);
      final String old = p.join(src.path, 'p3.zip');
      await rewriteZip(
        e.zip,
        old,
        drop: (String n) => n.startsWith('srs/'),
        add: <String, List<int>>{'srs.db': File(p3).readAsBytesSync()},
      );
      final String dbDir = await seedTarget();
      for (int round = 0; round < 2; round++) {
        await BackupRestoreService.mergeRestoreBackup(
          dbDirectory: dbDir,
          zipPath: old,
          srsConfirmed: true,
        );
      }
      await onTarget(dbDir, (FushiDatabase db, SrsStorage srs) async {
        final String uid = (await uidOfName(db, '日语'))!;
        final Map<String, List<String>> got = await tables(
          srs.core,
          uid,
          withProfile: false,
        );
        expect(count(got, 'logs'), count(e.tables, 'logs'));
        expect(_notes(got), _notes(e.tables));
        expect(_cards(got), _cards(e.tables));
      });
    });
  });
}

Iterable<String> _ofKind(Map<String, List<String>> t, String kind) =>
    t['entities']!
        .where((String r) => r.split('|')[1] == kind)
        .map((String r) => r.split('|').first);

List<String> _notes(Map<String, List<String>> t) =>
    _ofKind(t, 'note').toList()..sort();

List<String> _cards(Map<String, List<String>> t) =>
    _ofKind(t, 'card').toList()..sort();

Future<bool> _hasLegacyTables(DatabaseConnectionUser db) async =>
    (await db
        .customSelect(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' "
          "AND name = 'srs_entities'",
        )
        .getSingleOrNull()) !=
    null;

/// 2026-10-23 之前的形态：把 [events]（v1）按旧表定义写进主库 [db]（卡片 → 笔记写进 `srs_cards_cache`）。
Future<void> _writeLegacyTables(
  FushiDatabase db,
  List<SrsEvent> events,
  Map<String, String> noteOfCard,
) async {
  for (final String ddl in kLegacySrsTableDdl.values) {
    await db.customStatement(ddl);
  }
  for (final SrsEvent e in events) {
    switch (e) {
      case SrsEntityEvent(:final SrsEntityRecord record):
        await db.customStatement(
          'INSERT INTO srs_entities (id, profile_uid, kind, payload_json) '
          'VALUES (?, ?, ?, ?)',
          <Object?>[
            record.id,
            record.profileUid,
            record.kind.wire,
            jsonEncode(record.payload),
          ],
        );
      case SrsEditEvent(:final SrsFieldEdit edit):
        await db.customStatement(
          'INSERT INTO srs_field_edits (id, profile_uid, entity_kind, '
          'entity_id, field_key, writer_id, seq, json) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            edit.id,
            edit.profileUid,
            edit.entityKind.wire,
            edit.entityId,
            edit.fieldKey,
            edit.dot.writerId,
            edit.dot.seq,
            jsonEncode(edit.toJson()),
          ],
        );
      case SrsLogEvent(:final SrsReviewLog log):
        final Map<String, Object?> j = log.toJson();
        await db.customStatement(
          'INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, '
          'occurred_at, review_type, origin, json) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            log.id,
            log.profileUid,
            log.cardId,
            '${j['kind']}',
            j['rating'],
            log.occurredAt,
            '${j['rtype'] ?? 'manual'}',
            '${j['origin'] ?? 'fushi'}',
            jsonEncode(j),
          ],
        );
      case SrsUnknownEvent():
        break;
    }
  }
  final String profile = events.first.toJson()['x'] is Map
      ? ((events.first.toJson()['x']! as Map)['p'] as String)
      : '';
  for (final MapEntry<String, String> c in noteOfCard.entries) {
    await db.customStatement(
      'INSERT INTO srs_cards_cache (id, profile_uid, note_id, template_id, '
      'deck_id) VALUES (?, ?, ?, ?, ?)',
      <Object?>[c.key, profile, c.value, 't', 'd'],
    );
  }
}

/// 一份真的协议 3 库（2026-10-23 起整包备份里的 `srs.db` 条目那种）：把 [e] 的源数据按 v1 事件交给内核
/// `legacy_backup_import`（只预检），内核用冻结的协议 3 代码在 scratch 目录里备好的那份库就是。
Future<String> _protocol3LibraryFrom(
  Directory root,
  ({String zip, String uid, Map<String, List<String>> tables}) e,
) async {
  final Directory work = Directory(p.join(root.path, 'p3work'))
    ..createSync(recursive: true);
  final Directory scratch = Directory(p.join(work.path, 'scratch'))
    ..createSync();
  final Directory lib = Directory(p.join(work.path, 'lib'))..createSync();
  // 源数据：从整包备份新形态的流导进一份临时新代库，再读 v1 事件。
  final Archive archive = ZipDecoder().decodeBytes(
    File(e.zip).readAsBytesSync(),
  );
  final SrsBackupBundleManifest m = SrsBackupBundleManifest.parse(
    archive.findFile(kSrsBackupManifestEntry)!.content as List<int>,
  );
  final String stream = p.join(work.path, '0.bin');
  File(stream).writeAsBytesSync(
    archive.findFile(srsBackupStreamEntry(0))!.content as List<int>,
  );
  final SrsCore core = SrsCore.open(lib.path);
  try {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await srsLandBackupUnit(
      core: core,
      targetUid: e.uid,
      file: SrsBackupStreamFile(path: stream, unit: m.units.single),
      confirmed: true,
      nowMs: now,
    );
    final List<SrsEvent> events = await srsEventsOf(core, e.uid);
    final String jsonl = p.join(work.path, 'events.jsonl');
    final Map<String, String> noteOfCard = <String, String>{};
    for (final SrsEvent ev in events) {
      if (ev is SrsEntityEvent && ev.record.kind == SrsEntityKind.card) {
        final Object? n = ev.record.payload['noteId'];
        if (n is String) noteOfCard[ev.record.id] = n;
      }
    }
    await srsWriteLegacyEventsJsonl(
      events,
      File(jsonl),
      noteOfCard: noteOfCard,
    );
    // 另一份空的新代库上预检：上面那份里这个集合已经绑在 e.uid 上了。
    final Directory fresh = Directory(p.join(work.path, 'fresh'))..createSync();
    final SrsCore other = SrsCore.open(fresh.path);
    try {
      await srsLandBackupUnit(
        core: other,
        targetUid: e.uid,
        file: SrsBackupLegacyEventsFile(
          path: jsonl,
          scratch: scratch.path,
          backupProfile: e.uid,
        ),
        confirmed: false,
        preflight: true,
        nowMs: now,
      );
    } finally {
      other.close();
    }
  } finally {
    core.close();
  }
  return p.join(scratch.path, kSrsDatabaseFileName);
}
