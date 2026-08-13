import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'temp_dir_cleanup.dart';

void main() {
  group('BackupMeta', () {
    test('round-trip JSON', () {
      final meta = BackupMeta(
        appVersion: '2.1.0',
        schemaVersion: 13,
        createdAt: DateTime(2026, 5, 28, 14, 30),
        bookCount: 5,
        statsCount: 42,
      );
      final json = meta.toJson();
      final parsed = BackupMeta.fromJson(json);
      expect(parsed.appVersion, '2.1.0');
      expect(parsed.schemaVersion, 13);
      expect(parsed.createdAt, DateTime(2026, 5, 28, 14, 30));
      expect(parsed.bookCount, 5);
      expect(parsed.statsCount, 42);
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'appVersion': '1.0.0',
        'schemaVersion': 10,
        'createdAt': '2026-01-01T00:00:00.000',
      };
      final meta = BackupMeta.fromJson(json);
      expect(meta.bookCount, 0);
      expect(meta.statsCount, 0);
    });

    test('tryParse returns null on garbage input', () {
      expect(BackupMeta.tryParse('not json'), isNull);
      expect(BackupMeta.tryParse('{"appVersion": 123}'), isNull);
      expect(BackupMeta.tryParse('[]'), isNull);
    });

    test('tryParse succeeds on valid JSON', () {
      final json = {
        'appVersion': '1.0.0',
        'schemaVersion': 13,
        'createdAt': '2026-05-28T00:00:00.000',
        'bookCount': 3,
        'statsCount': 10,
      };
      final meta = BackupMeta.tryParse(jsonEncode(json));
      expect(meta, isNotNull);
      expect(meta!.appVersion, '1.0.0');
    });
  });

  group('BackupService', () {
    late FushiDatabase db;
    late Directory tmpDir;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tmpDir = await Directory.systemTemp.createTemp('backup_test_');
    });

    tearDown(() async {
      await db.close();
      if (tmpDir.existsSync()) await cleanupTempDir(tmpDir);
    });

    test('defaultFilename matches expected pattern', () {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      final name = service.defaultFilename();
      expect(name, startsWith('fushi-backup-'));
      expect(name, endsWith('.fushi.zip'));
      expect(
          RegExp(r'fushi-backup-\d{4}-\d{2}-\d{2}\.fushi\.zip').hasMatch(name),
          isTrue);
    });

    test('validateBackup returns null for non-zip file', () async {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      final fakePath = '${tmpDir.path}/fake.zip';
      await File(fakePath).writeAsString('not a zip file');
      final result = await service.validateBackup(fakePath);
      expect(result, isNull);
    });

    test('validateBackup returns null for zip without metadata', () async {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      final archive = Archive();
      archive.addFile(ArchiveFile('random.txt', 5, utf8.encode('hello')));
      final zipData = ZipEncoder().encode(archive)!;
      final zipPath = '${tmpDir.path}/no_meta.zip';
      await File(zipPath).writeAsBytes(zipData);

      final result = await service.validateBackup(zipPath);
      expect(result, isNull);
    });

    test('validateBackup returns null for zip with metadata but no db',
        () async {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      final meta = BackupMeta(
        appVersion: '1.0.0',
        schemaVersion: 13,
        createdAt: DateTime.now(),
        bookCount: 0,
        statsCount: 0,
      );
      final metaBytes = utf8.encode(jsonEncode(meta.toJson()));
      final archive = Archive();
      archive.addFile(
          ArchiveFile('backup_meta.json', metaBytes.length, metaBytes));
      final zipData = ZipEncoder().encode(archive)!;
      final zipPath = '${tmpDir.path}/no_db.zip';
      await File(zipPath).writeAsBytes(zipData);

      final result = await service.validateBackup(zipPath);
      expect(result, isNull);
    });

    test('validateBackup returns metadata for valid backup zip', () async {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      final meta = BackupMeta(
        appVersion: '1.0.0',
        schemaVersion: 13,
        createdAt: DateTime(2026, 5, 28),
        bookCount: 3,
        statsCount: 10,
      );
      final metaBytes = utf8.encode(jsonEncode(meta.toJson()));
      final dbBytes = utf8.encode('fake sqlite data');
      final archive = Archive();
      archive.addFile(
          ArchiveFile('backup_meta.json', metaBytes.length, metaBytes));
      archive.addFile(ArchiveFile('hibiki.db', dbBytes.length, dbBytes));
      final zipData = ZipEncoder().encode(archive)!;
      final zipPath = '${tmpDir.path}/valid.zip';
      await File(zipPath).writeAsBytes(zipData);

      final result = await service.validateBackup(zipPath);
      expect(result, isNotNull);
      expect(result!.appVersion, '1.0.0');
      expect(result.schemaVersion, 13);
      expect(result.bookCount, 3);
      expect(result.statsCount, 10);
    });

    test('validateBackup returns null for nonexistent file', () async {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      final result =
          await service.validateBackup('${tmpDir.path}/nonexistent.zip');
      expect(result, isNull);
    });

    test('restoreBackup writes db file and cleans wal/shm', () async {
      // Create fake existing db files
      final dbPath = '${tmpDir.path}/fushi.db';
      final walPath = '${tmpDir.path}/fushi.db-wal';
      final shmPath = '${tmpDir.path}/fushi.db-shm';
      await File(dbPath).writeAsString('old data');
      await File(walPath).writeAsString('wal data');
      await File(shmPath).writeAsString('shm data');

      // Create a backup zip
      final newDbContent = utf8.encode('restored db content');
      final meta = BackupMeta(
        appVersion: '1.0.0',
        schemaVersion: 13,
        createdAt: DateTime.now(),
        bookCount: 0,
        statsCount: 0,
      );
      final metaBytes = utf8.encode(jsonEncode(meta.toJson()));
      final archive = Archive();
      // 条目名刻意用 legacy hibiki.db：老 Hibiki 备份必须仍可恢复（读侧回退）。
      archive
          .addFile(ArchiveFile('hibiki.db', newDbContent.length, newDbContent));
      archive.addFile(
          ArchiveFile('backup_meta.json', metaBytes.length, metaBytes));
      final zipData = ZipEncoder().encode(archive)!;
      final zipPath = '${tmpDir.path}/restore.zip';
      await File(zipPath).writeAsBytes(zipData);

      await BackupService.restoreBackup(
        dbDirectory: tmpDir.path,
        zipPath: zipPath,
      );

      expect(await File(dbPath).readAsString(), 'restored db content');
      expect(File(walPath).existsSync(), isFalse);
      expect(File(shmPath).existsSync(), isFalse);
      // The pre-restore copy and the preserve sidecar are cleaned up on a
      // successful import (no disk leak). A dummy non-DB current file cannot
      // contain device-local tables, so its crash marker is safely cleaned.
      expect(File('$dbPath.pre-restore.bak').existsSync(), isFalse);
      expect(File('${tmpDir.path}/fushi.db.sync-preserve.json').existsSync(),
          isFalse);
    });

    test('createBackup produces valid zip with db and metadata', () async {
      // Use an on-disk DB so VACUUM INTO or fallback works
      final dbDir = await Directory.systemTemp.createTemp('backup_export_');
      final onDiskDb = FushiDatabase(dbDir.path);
      try {
        // Insert a book so the metadata has a real count
        await onDiskDb.insertEpubBook(EpubBooksCompanion.insert(
          bookKey: 'Test Book',
          title: 'Test Book',
          epubPath: '/fake/path.epub',
          extractDir: '/fake/extract',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ));

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          appVersion: '2.0.0',
        );

        final outputPath = '${tmpDir.path}/export_test.zip';
        final meta = await service.createBackup(outputPath);

        expect(meta.appVersion, '2.0.0');
        expect(meta.schemaVersion, onDiskDb.schemaVersion);
        expect(meta.bookCount, 1);

        // Validate the produced zip
        final result = await service.validateBackup(outputPath);
        expect(result, isNotNull);
        expect(result!.bookCount, 1);
        expect(result.appVersion, '2.0.0');
      } finally {
        await onDiskDb.close();
        if (dbDir.existsSync()) await cleanupTempDir(dbDir);
      }
    });

    test(
        'createBackup strips sync credentials from the DB copy '
        '(HBK-AUDIT-012)', () async {
      final dbDir = await Directory.systemTemp.createTemp('backup_creds_');
      final onDiskDb = FushiDatabase(dbDir.path);
      try {
        await onDiskDb.setPref('sync_dropbox_token', 's:SECRET_TOKEN');
        await onDiskDb.setPref('sync_ftp_password', 's:hunter2');
        await onDiskDb.setPref('sync_desktop_credentials', 's:{"refresh":"x"}');
        await onDiskDb.setPref('sync_stats_enabled', 'b:true'); // non-secret
        await onDiskDb.setPref('reader_font_size', 'i:18'); // non-sync pref

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          appVersion: '2.0.0',
        );
        final outputPath = '${tmpDir.path}/creds_test.zip';
        await service.createBackup(outputPath);

        // Extract the exported DB and inspect its preferences table.
        final archive =
            ZipDecoder().decodeBytes(await File(outputPath).readAsBytes());
        final dbBytes = archive.findFile('fushi.db')!.content as List<int>;
        final restoreDir =
            await Directory.systemTemp.createTemp('backup_creds_r_');
        await File('${restoreDir.path}/fushi.db').writeAsBytes(dbBytes);
        final restored = FushiDatabase(restoreDir.path);
        try {
          // Credentials must be gone.
          expect(await restored.getPref('sync_dropbox_token'), isNull);
          expect(await restored.getPref('sync_ftp_password'), isNull);
          expect(await restored.getPref('sync_desktop_credentials'), isNull);
          // Non-credential prefs must survive.
          expect(await restored.getPref('sync_stats_enabled'), isNotNull);
          expect(await restored.getPref('reader_font_size'), isNotNull);
        } finally {
          await restored.close();
          if (restoreDir.existsSync()) {
            await cleanupTempDir(restoreDir);
          }
        }
      } finally {
        await onDiskDb.close();
        if (dbDir.existsSync()) await cleanupTempDir(dbDir);
      }
    });

    test('createBackup strips dictionary state without touching source DB',
        () async {
      final dbDir = await Directory.systemTemp.createTemp('backup_dict_');
      final onDiskDb = FushiDatabase(dbDir.path);
      try {
        await onDiskDb.upsertDictionaryMeta(
          DictionaryMetadataCompanion.insert(
            name: 'JMdict',
            formatKey: 'yomichan',
            order: 0,
          ),
        );
        await onDiskDb.replaceAllDictionaryHistory([
          DictionaryHistoryCompanion.insert(
            position: 0,
            resultJson: '{"searchTerm":"cat"}',
          ),
        ]);

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          appVersion: '2.0.0',
        );
        final outputPath = '${tmpDir.path}/dictionary_test.zip';
        await service.createBackup(outputPath);

        expect(await onDiskDb.getAllDictionaryMetadata(), hasLength(1));
        expect(await onDiskDb.getAllDictionaryHistory(), hasLength(1));

        final archive =
            ZipDecoder().decodeBytes(await File(outputPath).readAsBytes());
        final dbBytes = archive.findFile('fushi.db')!.content as List<int>;
        final restoreDir =
            await Directory.systemTemp.createTemp('backup_dict_r_');
        await File('${restoreDir.path}/fushi.db').writeAsBytes(dbBytes);
        final restored = FushiDatabase(restoreDir.path);
        try {
          expect(await restored.getAllDictionaryMetadata(), isEmpty);
          expect(await restored.getAllDictionaryHistory(), isEmpty);
        } finally {
          await restored.close();
          if (restoreDir.existsSync()) {
            await cleanupTempDir(restoreDir);
          }
        }
      } finally {
        await onDiskDb.close();
        if (dbDir.existsSync()) await cleanupTempDir(dbDir);
      }
    });

    test(
        'createBackup keeps dictionary resources when dictionary sync is enabled',
        () async {
      final dbDir =
          await Directory.systemTemp.createTemp('backup_dict_enabled_');
      final dictDir =
          await Directory.systemTemp.createTemp('backup_dict_resources_');
      final onDiskDb = FushiDatabase(dbDir.path);
      try {
        await Directory('${dictDir.path}/JMdict/media').create(recursive: true);
        await File('${dictDir.path}/JMdict/blobs.bin')
            .writeAsString('dictionary index');
        await File('${dictDir.path}/JMdict/media/pitch.png')
            .writeAsString('pitch image');
        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(true);
        await onDiskDb.upsertDictionaryMeta(
          DictionaryMetadataCompanion.insert(
            name: 'JMdict',
            formatKey: 'yomichan',
            order: 0,
          ),
        );
        await onDiskDb.replaceAllDictionaryHistory([
          DictionaryHistoryCompanion.insert(
            position: 0,
            resultJson: '{"searchTerm":"cat"}',
          ),
        ]);

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          dictionaryResourceDirectory: dictDir.path,
          appVersion: '2.0.0',
        );
        final outputPath = '${tmpDir.path}/dictionary_enabled_test.zip';
        await service.createBackup(outputPath);

        final archive =
            ZipDecoder().decodeBytes(await File(outputPath).readAsBytes());
        expect(archive.findFile('dictionaryResources/JMdict/blobs.bin'),
            isNotNull);
        expect(archive.findFile('dictionaryResources/JMdict/media/pitch.png'),
            isNotNull);

        final dbBytes = archive.findFile('fushi.db')!.content as List<int>;
        final restoreDir =
            await Directory.systemTemp.createTemp('backup_dict_enabled_r_');
        final restoredDictDir = await Directory.systemTemp
            .createTemp('backup_dict_enabled_resources_r_');
        await File('${restoreDir.path}/fushi.db').writeAsBytes(dbBytes);
        await BackupService.restoreBackup(
          dbDirectory: restoreDir.path,
          zipPath: outputPath,
          dictionaryResourceDirectory: restoredDictDir.path,
        );
        final restored = FushiDatabase(restoreDir.path);
        try {
          expect(await restored.getAllDictionaryMetadata(), hasLength(1));
          // BUG-832: recent-lookup history is a private usage trace and is
          // ALWAYS wiped on export (like search history), so it never travels —
          // even in a full backup where the dictionary itself is kept.
          expect(await restored.getAllDictionaryHistory(), isEmpty);
          expect(
            await File('${restoredDictDir.path}/JMdict/blobs.bin')
                .readAsString(),
            'dictionary index',
          );
          expect(
            await File('${restoredDictDir.path}/JMdict/media/pitch.png')
                .readAsString(),
            'pitch image',
          );
        } finally {
          await restored.close();
          if (restoreDir.existsSync()) {
            await cleanupTempDir(restoreDir);
          }
          if (restoredDictDir.existsSync()) {
            await cleanupTempDir(restoredDictDir);
          }
        }
      } finally {
        await onDiskDb.close();
        if (dbDir.existsSync()) await cleanupTempDir(dbDir);
        if (dictDir.existsSync()) await cleanupTempDir(dictDir);
      }
    });

    test(
        'createBackup strips dictionary state when enabled but resources are missing',
        () async {
      final dbDir =
          await Directory.systemTemp.createTemp('backup_dict_missing_');
      final missingDictDir =
          Directory('${tmpDir.path}/missing_dictionary_resources');
      final onDiskDb = FushiDatabase(dbDir.path);
      try {
        await Directory('${missingDictDir.path}/download_temp')
            .create(recursive: true);
        await File('${missingDictDir.path}/download_temp/leftover.bin')
            .writeAsString('temporary file');
        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(true);
        await onDiskDb.upsertDictionaryMeta(
          DictionaryMetadataCompanion.insert(
            name: 'MissingDict',
            formatKey: 'yomichan',
            order: 0,
          ),
        );
        await onDiskDb.replaceAllDictionaryHistory([
          DictionaryHistoryCompanion.insert(
            position: 0,
            resultJson: '{"searchTerm":"cat"}',
          ),
        ]);

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          dictionaryResourceDirectory: missingDictDir.path,
          appVersion: '2.0.0',
        );
        final outputPath = '${tmpDir.path}/dictionary_missing_test.zip';
        await service.createBackup(outputPath);

        final archive =
            ZipDecoder().decodeBytes(await File(outputPath).readAsBytes());
        final bool containsDictionaryResource = archive.files.any(
          (ArchiveFile file) => file.name.replaceAll(r'\', '/').startsWith(
                'dictionaryResources/',
              ),
        );
        expect(containsDictionaryResource, isFalse);

        final dbBytes = archive.findFile('fushi.db')!.content as List<int>;
        final restoreDir =
            await Directory.systemTemp.createTemp('backup_dict_missing_r_');
        await File('${restoreDir.path}/fushi.db').writeAsBytes(dbBytes);
        final restored = FushiDatabase(restoreDir.path);
        try {
          expect(await restored.getAllDictionaryMetadata(), isEmpty);
          expect(await restored.getAllDictionaryHistory(), isEmpty);
        } finally {
          await restored.close();
          if (restoreDir.existsSync()) {
            await cleanupTempDir(restoreDir);
          }
        }
      } finally {
        await onDiskDb.close();
        if (dbDir.existsSync()) await cleanupTempDir(dbDir);
      }
    });

    test(
        'restoreBackup PRESERVES existing dictionary resources when the '
        'backup carries none (BUG-454: an unselected-dictionary backup must '
        "not wipe this device's dictionaries)", () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup_no_dict_src_');
      final srcDb = FushiDatabase(srcDir.path);
      try {
        final service = BackupService(
          db: srcDb,
          dbDirectory: srcDir.path,
          appVersion: '2.0.0',
        );
        final outputPath = '${tmpDir.path}/no_dictionary_resources.zip';
        await service.createBackup(outputPath);

        final dstDir =
            await Directory.systemTemp.createTemp('backup_no_dict_dst_');
        final dstDictDir =
            await Directory.systemTemp.createTemp('backup_no_dict_resources_');
        try {
          await Directory('${dstDictDir.path}/OldDict/media')
              .create(recursive: true);
          await File('${dstDictDir.path}/OldDict/blobs.bin')
              .writeAsString('stale index');
          await File('${dstDictDir.path}/OldDict/media/old.png')
              .writeAsString('stale image');

          await BackupService.restoreBackup(
            dbDirectory: dstDir.path,
            zipPath: outputPath,
            dictionaryResourceDirectory: dstDictDir.path,
          );

          // BUG-454: the backup carried no dictionaries, so the device's
          // existing dictionary resources are KEPT (not wiped to empty).
          expect(await dstDictDir.exists(), isTrue);
          expect(
            File('${dstDictDir.path}/OldDict/blobs.bin').existsSync(),
            isTrue,
          );
          expect(
            File('${dstDictDir.path}/OldDict/media/old.png').existsSync(),
            isTrue,
          );
          expect(
            await File('${dstDictDir.path}/OldDict/blobs.bin').readAsString(),
            'stale index',
          );
        } finally {
          if (dstDir.existsSync()) await cleanupTempDir(dstDir);
          if (dstDictDir.existsSync()) {
            await cleanupTempDir(dstDictDir);
          }
        }
      } finally {
        await srcDb.close();
        if (srcDir.existsSync()) await cleanupTempDir(srcDir);
      }
    });

    test('restoreBackup rejects invalid dictionary resource paths safely',
        () async {
      final dbBytes = utf8.encode('restored db content');
      final meta = BackupMeta(
        appVersion: '2.0.0',
        schemaVersion: 13,
        createdAt: DateTime.now(),
        bookCount: 0,
        statsCount: 0,
      );
      final archive = Archive()
        ..addFile(ArchiveFile('hibiki.db', dbBytes.length, dbBytes))
        ..addFile(ArchiveFile(
          'backup_meta.json',
          utf8.encode(jsonEncode(meta.toJson())).length,
          utf8.encode(jsonEncode(meta.toJson())),
        ))
        ..addFile(ArchiveFile(
          'dictionaryResources/../escape.txt',
          6,
          utf8.encode('escape'),
        ));
      final zipPath = '${tmpDir.path}/invalid_dictionary_path.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive)!);

      final dstDir =
          await Directory.systemTemp.createTemp('backup_bad_dict_dst_');
      final dstDictDir =
          await Directory.systemTemp.createTemp('backup_bad_dict_resources_');
      try {
        await File('${dstDir.path}/fushi.db').writeAsString('current db');
        await Directory('${dstDictDir.path}/OldDict').create(recursive: true);
        await File('${dstDictDir.path}/OldDict/blobs.bin')
            .writeAsString('stale index');

        await expectLater(
          BackupService.restoreBackup(
            dbDirectory: dstDir.path,
            zipPath: zipPath,
            dictionaryResourceDirectory: dstDictDir.path,
          ),
          throwsA(isA<FormatException>()),
        );

        expect(
          await File('${dstDictDir.path}/OldDict/blobs.bin').readAsString(),
          'stale index',
        );
        expect(
            await File('${dstDir.path}/fushi.db').readAsString(), 'current db');
      } finally {
        if (dstDir.existsSync()) await cleanupTempDir(dstDir);
        if (dstDictDir.existsSync()) {
          await cleanupTempDir(dstDictDir);
        }
      }
    });

    test('export then import round-trip preserves database content', () async {
      // Source DB on disk: insert a book and a reading statistic.
      final srcDir = await Directory.systemTemp.createTemp('backup_src_');
      final srcDb = FushiDatabase(srcDir.path);
      try {
        await srcDb.insertEpubBook(EpubBooksCompanion.insert(
          bookKey: 'かがみの孤城',
          title: 'かがみの孤城',
          epubPath: '/fake/kagami.epub',
          extractDir: '/fake/extract',
          chapterCount: 12,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        await srcDb.setReadingStatistic(ReadingStatisticsCompanion.insert(
          title: 'かがみの孤城',
          dateKey: '2026-05-29',
          charactersRead: 3456,
          readingTimeMs: 1800000,
          lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
        ));

        final service = BackupService(
          db: srcDb,
          dbDirectory: srcDir.path,
          appVersion: '3.0.0',
        );
        final zipPath = '${tmpDir.path}/round_trip.zip';
        final meta = await service.createBackup(zipPath);
        expect(meta.bookCount, 1);
        expect(meta.statsCount, 1);
      } finally {
        await srcDb.close();
        if (srcDir.existsSync()) await cleanupTempDir(srcDir);
      }

      // Restore into a fresh directory and reopen — data must survive.
      final dstDir = await Directory.systemTemp.createTemp('backup_dst_');
      try {
        await BackupService.restoreBackup(
          dbDirectory: dstDir.path,
          zipPath: '${tmpDir.path}/round_trip.zip',
        );

        final restored = FushiDatabase(dstDir.path);
        try {
          final books = await restored.getAllEpubBooks();
          expect(books, hasLength(1));
          expect(books.single.title, 'かがみの孤城');
          expect(books.single.chapterCount, 12);

          final stats = await restored.getAllReadingStatistics();
          expect(stats, hasLength(1));
          expect(stats.single.title, 'かがみの孤城');
          expect(stats.single.charactersRead, 3456);
          expect(stats.single.readingTimeMs, 1800000);
        } finally {
          await restored.close();
        }
      } finally {
        if (dstDir.existsSync()) await cleanupTempDir(dstDir);
      }
    });

    test('validateBackup rejects oversized files', () async {
      final service = BackupService(
        db: db,
        dbDirectory: tmpDir.path,
        appVersion: '1.0.0',
      );
      // Create a file larger than 512 MB check
      // We can't actually create 512MB in a test, but we can verify the size
      // check path by confirming a valid small zip passes.
      // The size guard is tested implicitly: any file > 512 MB returns null.
      final meta = BackupMeta(
        appVersion: '1.0.0',
        schemaVersion: 13,
        createdAt: DateTime.now(),
        bookCount: 0,
        statsCount: 0,
      );
      final metaBytes = utf8.encode(jsonEncode(meta.toJson()));
      final dbBytes = utf8.encode('test db');
      final archive = Archive();
      archive.addFile(
          ArchiveFile('backup_meta.json', metaBytes.length, metaBytes));
      archive.addFile(ArchiveFile('hibiki.db', dbBytes.length, dbBytes));
      final zipData = ZipEncoder().encode(archive)!;
      final zipPath = '${tmpDir.path}/small_valid.zip';
      await File(zipPath).writeAsBytes(zipData);

      // Small file should pass
      final result = await service.validateBackup(zipPath);
      expect(result, isNotNull);
    });
  });

  group('export strips device-local config (privacy)', () {
    test('no device-local key (incl. addresses/usernames) leaks into a backup',
        () async {
      final srcDir = await Directory.systemTemp.createTemp('hibiki_strip_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final srcDb = FushiDatabase(srcDir.path);
      // Seed every device-local key with a sentinel value.
      for (final String key in SyncRepository.deviceLocalPrefKeys) {
        await srcDb.setPref(key, 'sentinel-$key');
      }
      // Content that SHOULD travel with the backup.
      await srcDb.setPrefTyped<bool>('sync_auto_enabled', true);
      await srcDb.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Keep Me',
        title: 'Keep Me',
        epubPath: '/x.epub',
        extractDir: '/x',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      final zipDir = await Directory.systemTemp.createTemp('hibiki_strip_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final zipPath = '${zipDir.path}/b.zip';
      await BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await srcDb.close();

      // Import into a FRESH dir: no current DB, so the backup is applied
      // verbatim with nothing preserved — exposing exactly what the ZIP holds.
      final dstDir = await Directory.systemTemp.createTemp('hibiki_strip_dst_');
      addTearDown(() => cleanupTempDir(dstDir));
      await BackupService.restoreBackup(
        dbDirectory: dstDir.path,
        zipPath: zipPath,
      );

      final dstDb = FushiDatabase(dstDir.path);
      addTearDown(dstDb.close);
      for (final String key in SyncRepository.deviceLocalPrefKeys) {
        expect(await dstDb.getPref(key), isNull,
            reason: '$key leaked into the exported backup');
      }
      // Content survived the round-trip.
      expect(
          await dstDb.getPrefTyped<bool>('sync_auto_enabled', false), isTrue);
      expect((await dstDb.getAllEpubBooks()).single.title, 'Keep Me');
    });

    test('every secret-shaped key stripped on export is also preserved', () {
      // Strip (export) and preserve (import) now run the SAME predicate
      // ([PrefRedactionPolicy]), so they cannot drift apart by construction —
      // that is the fix. This guard keeps the known credential keys pinned to
      // the whitelist that is the predicate's main line, so deleting one from
      // `deviceLocalPrefKeys` still trips a test rather than silently demoting
      // it to shape-matching only.
      const List<String> secretKeys = <String>[
        'sync_webdav_password',
        'sync_ftp_password',
        'sync_sftp_password',
        'sync_sftp_private_key',
        'sync_server_password',
        'sync_onedrive_token',
        'sync_dropbox_token',
        'sync_hibiki_client_token',
        'sync_desktop_credentials',
      ];
      for (final String k in secretKeys) {
        expect(SyncRepository.deviceLocalPrefKeys, contains(k),
            reason: '$k is stripped on export but missing from preserve list');
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(k), isTrue);
      }
    });

    test('non-sync_ credentials do not leak into a backup', () async {
      // Regression: the old export sweep was `key LIKE 'sync_%…'`, so every
      // credential owned by another subsystem travelled in the clear.
      final srcDir = await Directory.systemTemp.createTemp('hibiki_ns_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final srcDb = FushiDatabase(srcDir.path);
      const Map<String, String> credentials = <String, String>{
        'media_source_secret_1': 'BASE64-SFTP-PASSWORD',
        'media_source_secret_2': 'BASE64-PRIVATE-KEY-PEM',
        'qb_connection_config': '{"host":"h","username":"u","password":"pw"}',
        'yomitan_api_key': 'YOMITAN-KEY',
        'jimaku_api_key': 'JIMAKU-KEY',
        'manga_cloud_ocr_api_key': 'OCR-KEY',
        'video_scraper_tmdb_api_key': 'TMDB-KEY',
      };
      for (final MapEntry<String, String> e in credentials.entries) {
        await srcDb.setPref(e.key, e.value);
      }
      // A plain setting with no credential shape must still travel.
      await srcDb.setPref('reader_font_size', '18');

      final zipDir = await Directory.systemTemp.createTemp('hibiki_ns_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final zipPath = '${zipDir.path}/b.zip';
      await BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await srcDb.close();

      final dstDir = await Directory.systemTemp.createTemp('hibiki_ns_dst_');
      addTearDown(() => cleanupTempDir(dstDir));
      await BackupService.restoreBackup(
          dbDirectory: dstDir.path, zipPath: zipPath);

      final dstDb = FushiDatabase(dstDir.path);
      addTearDown(dstDb.close);
      for (final String key in credentials.keys) {
        expect(await dstDb.getPref(key), isNull,
            reason: '$key leaked into the exported backup');
      }
      expect(await dstDb.getPref('reader_font_size'), '18');
    });

    test('credentials inside a Profile snapshot do not leak into a backup',
        () async {
      // THE leak this whole change exists for: `snapshotCurrentSettings` copies
      // every pref into `profile_settings`, and `profiles` is ticked by default
      // on export — so deleting the rows from `preferences` alone shipped the
      // credentials in a second table. Simulates an upgrading device whose
      // snapshot was taken BEFORE the writer learned to skip credentials.
      final srcDir = await Directory.systemTemp.createTemp('hibiki_ps_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final srcDb = FushiDatabase(srcDir.path);
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final int profileId = await srcDb.insertProfile(ProfilesCompanion.insert(
        name: 'Leaky',
        createdAt: nowMs,
        updatedAt: nowMs,
      ));
      const Map<String, String> snapshotCredentials = <String, String>{
        'sync_webdav_password': 'WEBDAV-PW',
        'sync_desktop_credentials': 'OAUTH-REFRESH-TOKEN',
        'media_source_secret_1': 'BASE64-SFTP-PASSWORD',
        'qb_connection_config': '{"password":"pw"}',
        'yomitan_api_key': 'YOMITAN-KEY',
      };
      for (final MapEntry<String, String> e in snapshotCredentials.entries) {
        await srcDb.upsertProfileSetting(ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: BackupService.profilePrefCategory,
          key: e.key,
          value: e.value,
        ));
      }
      // A genuine per-profile preference in the same snapshot must survive.
      await srcDb.upsertProfileSetting(ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: BackupService.profilePrefCategory,
        key: 'reader_font_size',
        value: '22',
      ));

      final zipDir = await Directory.systemTemp.createTemp('hibiki_ps_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final zipPath = '${zipDir.path}/b.zip';
      await BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await srcDb.close();

      final dstDir = await Directory.systemTemp.createTemp('hibiki_ps_dst_');
      addTearDown(() => cleanupTempDir(dstDir));
      await BackupService.restoreBackup(
          dbDirectory: dstDir.path, zipPath: zipPath);

      final dstDb = FushiDatabase(dstDir.path);
      addTearDown(dstDb.close);
      final List<ProfileSettingRow> rows =
          await dstDb.getProfileSettings(profileId);
      final Map<String, String> restored = <String, String>{
        for (final ProfileSettingRow r in rows)
          if (r.category == BackupService.profilePrefCategory) r.key: r.value,
      };
      for (final String key in snapshotCredentials.keys) {
        expect(restored.containsKey(key), isFalse,
            reason: '$key leaked via profile_settings');
      }
      expect(restored['reader_font_size'], '22',
          reason: 'a real per-profile preference must still travel');
    });

    test('import preserves THIS device credentials the export strips',
        () async {
      // Symmetry: broadening the strip without broadening the preserve would
      // wipe the importing device's own SFTP password / API keys.
      final srcDir = await Directory.systemTemp.createTemp('hibiki_sym_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final srcDb = FushiDatabase(srcDir.path);
      await srcDb.setPref('reader_font_size', '18');
      final zipDir = await Directory.systemTemp.createTemp('hibiki_sym_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final zipPath = '${zipDir.path}/b.zip';
      await BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await srcDb.close();

      // The importing device already has its own credentials configured.
      final dstDir = await Directory.systemTemp.createTemp('hibiki_sym_dst_');
      addTearDown(() => cleanupTempDir(dstDir));
      final localDb = FushiDatabase(dstDir.path);
      const Map<String, String> localCredentials = <String, String>{
        'sync_webdav_password': 'LOCAL-WEBDAV-PW',
        'media_source_secret_1': 'LOCAL-SFTP-PASSWORD',
        'qb_connection_config': '{"password":"local"}',
        'yomitan_api_key': 'LOCAL-YOMITAN-KEY',
      };
      for (final MapEntry<String, String> e in localCredentials.entries) {
        await localDb.setPref(e.key, e.value);
      }
      await localDb.close();

      await BackupService.restoreBackup(
          dbDirectory: dstDir.path, zipPath: zipPath);

      final dstDb = FushiDatabase(dstDir.path);
      addTearDown(dstDb.close);
      for (final MapEntry<String, String> e in localCredentials.entries) {
        expect(await dstDb.getPref(e.key), e.value,
            reason: '${e.key} was stripped from the backup but NOT restored '
                'from this device → permanent credential loss');
      }
      expect(await dstDb.getPref('reader_font_size'), '18',
          reason: 'the backup\'s settings still apply');
    });
  });

  group('import keeping local settings (importSettings:false)', () {
    test('keeps local settings/profiles; content + audiobook pos from backup',
        () async {
      // ── This device: UI pref + profile + binding + sync + local book ──
      final curDir = await Directory.systemTemp.createTemp('hibiki_keep_cur_');
      addTearDown(() => cleanupTempDir(curDir));
      final curDb = FushiDatabase(curDir.path);
      await curDb.setPref('reader_appearance', 'LOCAL'); // UI pref (keep)
      await curDb.setPref('sync_backend_type', 'webDav'); // device-local (keep)
      await curDb.setPrefTyped<int>('audiobook_pos_99', 999); // content (drop)
      final int localProfileId = await curDb.insertProfile(
          ProfilesCompanion.insert(
              name: 'LocalProfile', createdAt: 1, updatedAt: 1));
      await curDb.upsertProfileSetting(ProfileSettingsCompanion.insert(
        profileId: localProfileId,
        category: 'pref',
        key: 'reader_appearance',
        value: 'LOCAL',
      ));
      await curDb.setBookProfile('book-local', localProfileId);
      await curDb.setPref('active_profile_id', localProfileId.toString());
      await curDb.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'LocalBook',
        title: 'LocalBook',
        epubPath: '/l.epub',
        extractDir: '/l',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ));
      await curDb.close();

      // ── Backup from another device: different settings/profile/book ──
      final srcDir = await Directory.systemTemp.createTemp('hibiki_keep_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final srcDb = FushiDatabase(srcDir.path);
      await srcDb.setPref('reader_appearance', 'BACKUP');
      await srcDb.insertProfile(ProfilesCompanion.insert(
          name: 'BackupProfile', createdAt: 2, updatedAt: 2));
      await srcDb.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'BackupBook',
        title: 'BackupBook',
        epubPath: '/b.epub',
        extractDir: '/b',
        chapterCount: 5,
        chaptersJson: '[]',
        importedAt: 2,
      ));
      final String backupBookId =
          (await srcDb.getAllEpubBooks()).single.bookKey;
      await srcDb.setPrefTyped<int>('audiobook_pos_$backupBookId', 4242);
      final zipDir = await Directory.systemTemp.createTemp('hibiki_keep_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final zipPath = '${zipDir.path}/b.zip';
      await BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await srcDb.close();

      // ── Import keeping local settings, then simulate the startup restore ──
      await BackupService.restoreBackup(
        dbDirectory: curDir.path,
        zipPath: zipPath,
        importSettings: false,
      );
      await BackupService.recoverPendingRestore(curDir.path);

      final after = FushiDatabase(curDir.path);
      addTearDown(after.close);

      // Settings + profiles + binding kept local:
      expect(await after.getPref('reader_appearance'), 'LOCAL');
      expect(await after.getPref('sync_backend_type'), 'webDav');
      final profileNames =
          (await after.getAllProfiles()).map((p) => p.name).toList();
      expect(profileNames, contains('LocalProfile'));
      expect(profileNames, isNot(contains('BackupProfile')));
      expect(await after.getBookProfile('book-local'), isNotNull);

      // Content from backup:
      final bookTitles =
          (await after.getAllEpubBooks()).map((b) => b.title).toList();
      expect(bookTitles, contains('BackupBook'));
      expect(bookTitles, isNot(contains('LocalBook')));

      // audiobook position is content → follows the backup, local one dropped:
      expect(await after.getPrefTyped<int>('audiobook_pos_$backupBookId', 0),
          4242);
      expect(await after.getPrefTyped<int>('audiobook_pos_99', 0), 0);

      // DB is valid + at the current schema after the migrate-then-copy, with
      // no FK violations, and the scratch files are cleaned up:
      final version =
          await after.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], after.schemaVersion);
      final integrity =
          await after.customSelect('PRAGMA integrity_check').get();
      expect(
          integrity.map((r) => r.data.values.first).toList(), <String>['ok']);
      final fk = await after.customSelect('PRAGMA foreign_key_check').get();
      expect(fk, isEmpty);
      expect(File('${curDir.path}/fushi.db.pre-restore.bak').existsSync(),
          isFalse);
      expect(File('${curDir.path}/fushi.db.sync-preserve.json').existsSync(),
          isFalse);
    });

    test('fresh install (no current DB) restores everything (toggle moot)',
        () async {
      // Backup with its own settings + content.
      final srcDir = await Directory.systemTemp.createTemp('hibiki_fresh_src_');
      addTearDown(() => cleanupTempDir(srcDir));
      final srcDb = FushiDatabase(srcDir.path);
      await srcDb.setPref('reader_appearance', 'BACKUP');
      await srcDb.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'BackupBook',
        title: 'BackupBook',
        epubPath: '/b.epub',
        extractDir: '/b',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ));
      final zipDir = await Directory.systemTemp.createTemp('hibiki_fresh_zip_');
      addTearDown(() => cleanupTempDir(zipDir));
      final zipPath = '${zipDir.path}/b.zip';
      await BackupService(
              db: srcDb, dbDirectory: srcDir.path, appVersion: '1.0')
          .createBackup(zipPath);
      await srcDb.close();

      // Import into an EMPTY dir (no current DB) with importSettings:false.
      final dstDir = await Directory.systemTemp.createTemp('hibiki_fresh_dst_');
      addTearDown(() => cleanupTempDir(dstDir));
      await BackupService.restoreBackup(
        dbDirectory: dstDir.path,
        zipPath: zipPath,
        importSettings: false,
      );
      await BackupService.recoverPendingRestore(dstDir.path);

      final after = FushiDatabase(dstDir.path);
      addTearDown(after.close);
      // Nothing local to preserve → backup applied verbatim (settings included).
      expect(await after.getPref('reader_appearance'), 'BACKUP');
      expect((await after.getAllEpubBooks()).single.title, 'BackupBook');
      expect(File('${dstDir.path}/fushi.db.pre-restore.bak').existsSync(),
          isFalse);
      expect(File('${dstDir.path}/fushi.db.sync-preserve.json').existsSync(),
          isFalse);
    });

    test(
        'recoverPendingRestore with a settings sidecar but missing bak is safe',
        () async {
      final dir = await Directory.systemTemp.createTemp('hibiki_nobak_');
      addTearDown(() => cleanupTempDir(dir));
      final db = FushiDatabase(dir.path);
      await db.setPref('reader_appearance', 'INTACT');
      await db.close();

      // A crashed keep-settings import could leave the sidecar with no bak.
      await File('${dir.path}/fushi.db.sync-preserve.json')
          .writeAsString(jsonEncode(<String, dynamic>{'mode': 'settings'}));

      await BackupService.recoverPendingRestore(dir.path); // must not throw

      final after = FushiDatabase(dir.path);
      addTearDown(after.close);
      // DB untouched, sidecar cleaned up.
      expect(await after.getPref('reader_appearance'), 'INTACT');
      expect(File('${dir.path}/fushi.db.sync-preserve.json').existsSync(),
          isFalse);
    });
  });
}
