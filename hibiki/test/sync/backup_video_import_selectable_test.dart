import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-779: videos live in the overwrite DB blob (video_books + cascade) and
/// restore wholesale, but the import dialog decided "has videos" from PACKED
/// FILES only. A backup with video ROWS but no packed files (streaming/http
/// videos, an old backup, or files that could not travel) hid the video category
/// entirely → videos imported uninvited AND the overwrite import never stripped
/// the rows even if the toggle had been shown. Fix: record the blob's
/// video_books count in meta (+ a DB-blob peek for old backups) so the dialog
/// offers the toggle, and strip video_books on import when the category is off.
void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_vsel_src_');
    dst = await Directory.systemTemp.createTemp('bk_vsel_dst_');
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

  Future<void> writeFile(String path, String content) async {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  Future<int> countRows(HibikiDatabase db, String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.data['c'] as int;
  }

  group('export records the blob video_books count in meta', () {
    test('videos ticked → videoBookCount = every row; unticked → 0', () async {
      final String dbDir = p.join(src.path, 'db');
      final String videos = p.join(src.path, 'external_videos');
      Directory(dbDir).createSync(recursive: true);
      await writeFile(p.join(videos, 'A.mp4'), 'VID-A');
      await writeFile(p.join(videos, 'B.mp4'), 'VID-B');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      for (final String k in <String>['A', 'B']) {
        await db.upsertVideoBook(VideoBooksCompanion.insert(
          bookUid: 'video/$k',
          title: 'Video $k',
          videoPath: p.join(videos, '$k.mp4'),
        ));
      }
      final BackupService service =
          BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');

      final BackupMeta withVideos =
          await service.createBackup(p.join(src.path, 'with.zip'));
      expect(withVideos.videoBookCount, 2);

      final BackupMeta noVideos = await service.createBackup(
        p.join(src.path, 'without.zip'),
        categories: BackupCategory.values.toSet()
          ..remove(BackupCategory.videos),
      );
      await db.close();
      expect(noVideos.videoBookCount, 0);
    });
  });

  group('summarizeBackupEntries video visibility', () {
    BackupMeta metaWith({int? videoBookCount}) => BackupMeta(
          appVersion: '1.0.0',
          schemaVersion: 1,
          createdAt: DateTime(2026, 7, 7),
          bookCount: 0,
          statsCount: 0,
          videoBookCount: videoBookCount,
        );

    test('meta.videoBookCount>0 shows videos even with NO packed files', () {
      final BackupContentSummary s = BackupService.summarizeBackupEntries(
        <String>['hibiki.db', 'backup_meta.json'],
        metaWith(videoBookCount: 3),
      );
      expect(s.has(BackupCategory.videos), isTrue);
      expect(s.countFor(BackupCategory.videos), 3);
    });

    test('meta.videoBookCount==0 hides videos (unticked new backup)', () {
      final BackupContentSummary s = BackupService.summarizeBackupEntries(
        <String>['hibiki.db'],
        metaWith(videoBookCount: 0),
        dbVideoBookCount: 9, // authoritative meta 0 must win over any peek
      );
      expect(s.has(BackupCategory.videos), isFalse);
    });

    test('old backup (meta lacks the field) falls back to the DB peek', () {
      final BackupContentSummary s = BackupService.summarizeBackupEntries(
        <String>['hibiki.db'],
        metaWith(), // videoBookCount == null
        dbVideoBookCount: 2,
      );
      expect(s.has(BackupCategory.videos), isTrue);
      expect(s.countFor(BackupCategory.videos), 2);
    });
  });

  test(
      'summarizeBackupFile peeks the DB blob so an OLD backup (video rows, no '
      'files, no meta count) still offers the video toggle (BUG-779)',
      () async {
    // Build the user's exact scenario: a backup whose hibiki.db carries
    // video_books rows, packs NO video files, and whose meta predates
    // videoBookCount.
    final String oldDbDir = p.join(src.path, 'olddb');
    Directory(oldDbDir).createSync(recursive: true);
    final HibikiDatabase db = HibikiDatabase(oldDbDir);
    for (final String k in <String>['1', '2']) {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'v/$k',
        title: 'Show $k',
        videoPath: '/gone/$k.mp4', // file no longer exists → nothing to pack
      ));
    }
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.close();
    final List<int> dbBytes =
        File(p.join(oldDbDir, 'hibiki.db')).readAsBytesSync();

    // Meta WITHOUT videoBookCount (older schema) and NO videos/ entries.
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

    expect(summary.has(BackupCategory.videos), isTrue,
        reason: 'the DB-blob peek must reveal the 2 video rows');
    expect(summary.countFor(BackupCategory.videos), 2);
  });

  group('overwrite import honors the video toggle', () {
    Future<String> exportWithTwoVideos() async {
      final String dbDir = p.join(src.path, 'db');
      final String videos = p.join(src.path, 'external_videos');
      Directory(dbDir).createSync(recursive: true);
      await writeFile(p.join(videos, 'A.mp4'), 'VID-A');
      await writeFile(p.join(videos, 'B.mp4'), 'VID-B');
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      for (final String k in <String>['A', 'B']) {
        await db.upsertVideoBook(VideoBooksCompanion.insert(
          bookUid: 'video/$k',
          title: 'Video $k',
          videoPath: p.join(videos, '$k.mp4'),
        ));
      }
      final BackupService service =
          BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');
      final String zip = p.join(src.path, 'videos.zip');
      await service.createBackup(zip);
      await db.close();
      return zip;
    }

    test('unticking videos strips every video_books row on import', () async {
      final String zip = await exportWithTwoVideos();
      final String dstDbDir = p.join(dst.path, 'db');
      Directory(dstDbDir).createSync(recursive: true);

      await BackupService.restoreBackup(
        dbDirectory: dstDbDir,
        zipPath: zip,
        categories: BackupCategory.values.toSet()
          ..remove(BackupCategory.videos),
      );

      final HibikiDatabase after = HibikiDatabase(dstDbDir);
      addTearDown(after.close);
      expect(await countRows(after, 'video_books'), 0);
    });

    test('keeping videos restores the video_books rows', () async {
      final String zip = await exportWithTwoVideos();
      final String dstDbDir = p.join(dst.path, 'db');
      Directory(dstDbDir).createSync(recursive: true);

      await BackupService.restoreBackup(
        dbDirectory: dstDbDir,
        zipPath: zip, // null categories = restore everything (incl. videos)
      );

      final HibikiDatabase after = HibikiDatabase(dstDbDir);
      addTearDown(after.close);
      expect(await countRows(after, 'video_books'), 2);
    });
  });
}
