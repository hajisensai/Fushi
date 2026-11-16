// G7-5 复核修复：复习换代之后，备份带复习数据时覆盖恢复 / 合并导入在动任何文件之前拒绝
// （restore.part.dart `SrsRestoreUnavailableException`）。协议 3 的还原会删 / 换本机 `srs.db`——迁移之后那是原位
// 封存的无损回退副本。新代还原归 G11-4；在那之前，本机的 `srs.db` / `srs4.db` 一个字节都不能动。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

BackupMeta _meta({int? srsNotes, Set<String> excluded = const <String>{}}) =>
    BackupMeta(
      appVersion: '0.0.0',
      schemaVersion: 1,
      createdAt: DateTime.utc(2026, 11, 17),
      bookCount: 0,
      statsCount: 0,
      srsNoteCount: srsNotes,
      excludedCategories: excluded,
    );

Archive _archive(List<String> names) {
  final Archive a = Archive();
  for (final String n in names) {
    a.addFile(ArchiveFile(n, 1, <int>[0]));
  }
  return a;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('backupCarriesSrs', () {
    test('new-shape srs.db entry or srs media means it carries SRS', () {
      expect(
        BackupRestoreService.backupCarriesSrs(
          _archive(<String>['srs.db']),
          _meta(srsNotes: 0),
        ),
        isTrue,
      );
      expect(
        BackupRestoreService.backupCarriesSrs(
          _archive(<String>['srs_media/u/a.png']),
          _meta(srsNotes: 0),
        ),
        isTrue,
      );
      expect(
        BackupRestoreService.backupCarriesSrs(
          _archive(<String>[]),
          _meta(srsNotes: 3),
        ),
        isTrue,
      );
    });

    test('old shape (no count in meta / no meta) counts as carrying', () {
      expect(
        BackupRestoreService.backupCarriesSrs(_archive(<String>[]), _meta()),
        isTrue,
      );
      expect(
        BackupRestoreService.backupCarriesSrs(_archive(<String>[]), null),
        isTrue,
      );
    });

    test('no SRS notes / SRS excluded at export: does not carry', () {
      expect(
        BackupRestoreService.backupCarriesSrs(
          _archive(<String>[]),
          _meta(srsNotes: 0),
        ),
        isFalse,
      );
      expect(
        BackupRestoreService.backupCarriesSrs(
          _archive(<String>['srs.db']),
          _meta(excluded: <String>{BackupCategory.srs.name}),
        ),
        isFalse,
      );
    });
  });

  group('restore with SRS data is refused before any file changes', () {
    late Directory src;
    late Directory dst;
    late String zip;
    late String dbDir;

    setUp(() async {
      src = await Directory.systemTemp.createTemp('bk_srs_refuse_src_');
      dst = await Directory.systemTemp.createTemp('bk_srs_refuse_dst_');
      // 备份：一份真的主库 + `srs.db` 条目 + meta。
      final FushiDatabase db = FushiDatabase(src.path);
      await db.customStatement('SELECT 1');
      final int schema =
          (await db.customSelect('PRAGMA user_version').getSingle())
                  .data
                  .values
                  .single
              as int;
      await db.close();
      final List<int> mainDb = File(
        p.join(src.path, fushiDatabaseFileName),
      ).readAsBytesSync();
      final List<int> meta = utf8.encode(
        jsonEncode(
          BackupMeta(
            appVersion: '0.0.0',
            schemaVersion: schema,
            createdAt: DateTime.utc(2026, 11, 17),
            bookCount: 0,
            statsCount: 0,
            srsNoteCount: 1,
          ).toJson(),
        ),
      );
      final List<int> srs = utf8.encode('backup');
      final Archive a = Archive()
        ..addFile(ArchiveFile(fushiDatabaseFileName, mainDb.length, mainDb))
        ..addFile(ArchiveFile(kSrsDatabaseFileName, srs.length, srs))
        ..addFile(ArchiveFile('backup_meta.json', meta.length, meta));
      zip = p.join(src.path, 'b.zip');
      File(zip).writeAsBytesSync(ZipEncoder().encode(a)!);
      // 本机：迁移过的目录（新代库 + 原位封存的旧库）。
      dbDir = p.join(dst.path, 'support');
      Directory(dbDir).createSync(recursive: true);
      File(SrsStorage.legacyPathIn(dbDir)).writeAsStringSync('SEALED');
      File(SrsStorage.gen4PathIn(dbDir)).writeAsStringSync('GEN4');
    });
    tearDown(() async {
      for (final Directory d in <Directory>[src, dst]) {
        if (d.existsSync()) await cleanupTempDir(d);
      }
    });

    void expectUntouched() {
      expect(File(SrsStorage.legacyPathIn(dbDir)).readAsStringSync(), 'SEALED');
      expect(File(SrsStorage.gen4PathIn(dbDir)).readAsStringSync(), 'GEN4');
      final List<String> names = <String>[
        for (final FileSystemEntity e in Directory(dbDir).listSync())
          p.basename(e.path),
      ]..sort();
      expect(names, <String>[kSrsDatabaseFileName, kSrsGen4DatabaseFileName]);
    }

    test('overwrite restore', () async {
      await expectLater(
        BackupRestoreService.restoreBackup(dbDirectory: dbDir, zipPath: zip),
        throwsA(isA<SrsRestoreUnavailableException>()),
      );
      expectUntouched();
    });

    test('merge restore', () async {
      await expectLater(
        BackupRestoreService.mergeRestoreBackup(
          dbDirectory: dbDir,
          zipPath: zip,
        ),
        throwsA(isA<SrsRestoreUnavailableException>()),
      );
      expectUntouched();
    });

    test('the refusal reads as a clear message, not a raw error', () {
      LocaleSettings.setLocale(AppLocale.en);
      expect(
        friendlySyncErrorDetail(const SrsRestoreUnavailableException()),
        contains(t.backup_srs_restore_unavailable),
      );
    });
  });
}
