import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-781: audiobooks are the same class of bug as videos (BUG-779). The
/// `audiobooks` table (+ audio_cues + the `srt` shelf entry) rides the overwrite
/// DB blob and restores wholesale, but the import dialog decided "has audiobooks"
/// from PACKED FILES only, and the import-side category strip covered
/// books/videos/statistics/progress but NOT audiobooks. So unticking the
/// audiobooks category never removed the rows → a "ghost audiobook" (shelf entry
/// + alignment rows) whose audio never travelled. Fix: record the blob's
/// audiobook count in meta (+ a DB-blob peek for old backups) so the toggle
/// appears, and strip audiobooks on import when the category is off.
void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_absel_src_');
    dst = await Directory.systemTemp.createTemp('bk_absel_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      try {
        if (d.existsSync()) await cleanupTempDir(d);
      } on PathNotFoundException {
        // Windows recursive temp cleanup can race.
      }
    }
  });

  Future<int> countRows(HibikiDatabase db, String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.data['c'] as int;
  }

  Future<void> seedTwoAudiobooks(HibikiDatabase db) async {
    for (final String k in <String>['bookA', 'bookB']) {
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: k,
        alignmentFormat: 'srt',
        alignmentPath: '/gone/$k.srt',
      ));
    }
  }

  group('export records the blob audiobook count in meta', () {
    test('audiobooks ticked → count = rows; unticked → 0 + rows stripped',
        () async {
      final String dbDir = p.join(src.path, 'db');
      Directory(dbDir).createSync(recursive: true);
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await seedTwoAudiobooks(db);
      final BackupService service =
          BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');

      final BackupMeta withAb =
          await service.createBackup(p.join(src.path, 'with.zip'));
      expect(withAb.audiobookCount, 2);

      final BackupMeta noAb = await service.createBackup(
        p.join(src.path, 'without.zip'),
        categories: BackupCategory.values.toSet()
          ..remove(BackupCategory.audiobooks),
      );
      await db.close();
      expect(noAb.audiobookCount, 0);
    });
  });

  group('summarizeBackupEntries audiobook visibility', () {
    BackupMeta metaWith({int? audiobookCount}) => BackupMeta(
          appVersion: '1.0.0',
          schemaVersion: 1,
          createdAt: DateTime(2026, 7, 7),
          bookCount: 0,
          statsCount: 0,
          audiobookCount: audiobookCount,
        );

    test('meta.audiobookCount>0 shows audiobooks even with NO packed files',
        () {
      final BackupContentSummary s = BackupService.summarizeBackupEntries(
        <String>['hibiki.db'],
        metaWith(audiobookCount: 3),
      );
      expect(s.has(BackupCategory.audiobooks), isTrue);
      expect(s.countFor(BackupCategory.audiobooks), 3);
    });

    test('meta.audiobookCount==0 hides audiobooks (unticked new backup)', () {
      final BackupContentSummary s = BackupService.summarizeBackupEntries(
        <String>['hibiki.db'],
        metaWith(audiobookCount: 0),
        dbAudiobookCount: 9, // authoritative meta 0 wins over any peek
      );
      expect(s.has(BackupCategory.audiobooks), isFalse);
    });

    test('old backup (meta lacks the field) falls back to the DB peek', () {
      final BackupContentSummary s = BackupService.summarizeBackupEntries(
        <String>['hibiki.db'],
        metaWith(), // audiobookCount == null
        dbAudiobookCount: 2,
      );
      expect(s.has(BackupCategory.audiobooks), isTrue);
      expect(s.countFor(BackupCategory.audiobooks), 2);
    });
  });

  test(
      'summarizeBackupFile peeks the DB blob so an OLD backup (audiobook rows, no '
      'files, no meta count) still offers the audiobooks toggle (BUG-781)',
      () async {
    final String oldDbDir = p.join(src.path, 'olddb');
    Directory(oldDbDir).createSync(recursive: true);
    final HibikiDatabase db = HibikiDatabase(oldDbDir);
    await seedTwoAudiobooks(db);
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.close();
    final List<int> dbBytes =
        File(p.join(oldDbDir, 'hibiki.db')).readAsBytesSync();

    // Meta WITHOUT audiobookCount (older schema) and NO audiobooks/ entries.
    final List<int> metaBytes = utf8.encode(jsonEncode(<String, Object?>{
      'appVersion': '1.0.0',
      'schemaVersion': db.schemaVersion,
      'createdAt': DateTime(2026, 7, 7).toIso8601String(),
      'bookCount': 0,
      'statsCount': 0,
    }));
    final Archive archive = Archive()
      ..addFile(ArchiveFile('hibiki.db', dbBytes.length, dbBytes))
      ..addFile(ArchiveFile('backup_meta.json', metaBytes.length, metaBytes));
    final String zip = p.join(src.path, 'old_backup.zip');
    File(zip).writeAsBytesSync(ZipEncoder().encode(archive)!);

    final HibikiDatabase dummy =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    final BackupService service =
        BackupService(db: dummy, dbDirectory: src.path, appVersion: '1.0.0');
    final BackupContentSummary summary = await service.summarizeBackupFile(zip);
    await dummy.close();

    expect(summary.has(BackupCategory.audiobooks), isTrue,
        reason: 'the DB-blob peek must reveal the 2 audiobook rows');
    expect(summary.countFor(BackupCategory.audiobooks), 2);
  });

  group('overwrite import honors the audiobooks toggle', () {
    Future<String> exportWithTwoAudiobooks() async {
      final String dbDir = p.join(src.path, 'db');
      Directory(dbDir).createSync(recursive: true);
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await seedTwoAudiobooks(db);
      final BackupService service =
          BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');
      final String zip = p.join(src.path, 'ab.zip');
      await service.createBackup(zip);
      await db.close();
      return zip;
    }

    test('unticking audiobooks strips every audiobooks row on import',
        () async {
      final String zip = await exportWithTwoAudiobooks();
      final String dstDbDir = p.join(dst.path, 'db');
      Directory(dstDbDir).createSync(recursive: true);

      await BackupService.restoreBackup(
        dbDirectory: dstDbDir,
        zipPath: zip,
        categories: BackupCategory.values.toSet()
          ..remove(BackupCategory.audiobooks),
      );

      final HibikiDatabase after = HibikiDatabase(dstDbDir);
      addTearDown(after.close);
      expect(await countRows(after, 'audiobooks'), 0);
    });

    test('keeping audiobooks restores the audiobooks rows', () async {
      final String zip = await exportWithTwoAudiobooks();
      final String dstDbDir = p.join(dst.path, 'db');
      Directory(dstDbDir).createSync(recursive: true);

      await BackupService.restoreBackup(
        dbDirectory: dstDbDir,
        zipPath: zip, // null categories = restore everything (incl. audiobooks)
      );

      final HibikiDatabase after = HibikiDatabase(dstDbDir);
      addTearDown(after.close);
      expect(await countRows(after, 'audiobooks'), 2);
    });
  });
}
