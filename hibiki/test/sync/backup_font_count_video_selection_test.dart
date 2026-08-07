import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// The custom-font count / packing must reflect the fonts the USER manages
/// (catalog entries whose file lives under custom_fonts/), not every file in
/// the tree. Failed `_tmp_*` downloads and replaced-but-unreferenced old files
/// used to inflate both the export-dialog count and the packed archive (a user
/// with 2 fonts saw 7). Per-video export is the books analogue: [videoKeys]
/// packs ONLY the selected videos AND strips every other `video_books` row from
/// the DB copy so no "ghost video" survives a restore.
void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_fv_src_');
    dst = await Directory.systemTemp.createTemp('bk_fv_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      try {
        if (d.existsSync()) await cleanupTempDir(d);
      } on PathNotFoundException {
        // Windows recursive cleanup can race with already-removed temp paths.
      }
    }
  });

  Future<void> writeFile(String path, String content) async {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  Future<Archive> readZip(String zipPath) async {
    final InputFileStream input = InputFileStream(zipPath);
    try {
      return ZipDecoder().decodeBuffer(input);
    } finally {
      await input.close();
    }
  }

  Future<HibikiDatabase> openBackupDb(String zipPath, Directory into) async {
    final Archive archive = await readZip(zipPath);
    final ArchiveFile dbFile = archive.findFile('hibiki.db')!;
    final Directory dir = Directory(p.join(into.path, 'exdb'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'hibiki.db'))
        .writeAsBytesSync(dbFile.content as List<int>);
    return HibikiDatabase(dir.path);
  }

  Future<int> countRows(HibikiDatabase db, String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.data['c'] as int;
  }

  group('font count / packing = catalog entries, not raw file count', () {
    test('counts + packs only catalog-referenced files, skips orphans/temp',
        () async {
      final String dbDir = p.join(src.path, 'db');
      final String fonts = p.join(src.path, 'custom_fonts');
      Directory(dbDir).createSync(recursive: true);

      // Two managed fonts + three garbage files the tree accumulated: a failed
      // download temp file and two replaced-but-unreferenced old files.
      await writeFile(p.join(fonts, 'Klee.ttf'), 'FONT-A');
      await writeFile(p.join(fonts, 'Mincho.otf'), 'FONT-B');
      await writeFile(p.join(fonts, '_tmp_1700000000000'), 'HALF-DOWNLOAD');
      await writeFile(p.join(fonts, 'OldDeleted.ttf'), 'ORPHAN-1');
      await writeFile(p.join(fonts, 'AlsoUnreferenced.woff2'), 'ORPHAN-2');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await db.setPref(
        'src:reader_ttu:font_catalog',
        jsonEncode(<String, Object?>{
          'version': 1,
          'fonts': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'a',
              'name': 'Klee',
              'path': p.join(fonts, 'Klee.ttf'),
            },
            <String, Object?>{
              'id': 'b',
              'name': 'Mincho',
              'path': p.join(fonts, 'Mincho.otf'),
            },
          ],
        }),
      );

      final BackupService service = BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
        fontsRootDirectory: fonts,
      );

      // The five files on disk must NOT inflate the count: only the two
      // catalog entries are reported (root fix for "2 fonts shown as 7").
      final BackupContentSummary summary = await service.summarizeLiveContent();
      expect(summary.countFor(BackupCategory.fonts), 2);

      final String zip = p.join(src.path, 'fonts.zip');
      await service.createBackup(zip);
      await db.close();

      final Archive archive = await readZip(zip);
      expect(archive.findFile('custom_fonts/Klee.ttf'), isNotNull);
      expect(archive.findFile('custom_fonts/Mincho.otf'), isNotNull);
      // The garbage never travels.
      expect(archive.findFile('custom_fonts/_tmp_1700000000000'), isNull);
      expect(archive.findFile('custom_fonts/OldDeleted.ttf'), isNull);
      expect(archive.findFile('custom_fonts/AlsoUnreferenced.woff2'), isNull);
      // The archive font-file count agrees with the export-dialog count.
      final int packedFonts = archive.files
          .where((ArchiveFile f) =>
              f.isFile &&
              f.name.startsWith('custom_fonts/') &&
              f.name.length > 'custom_fonts/'.length)
          .length;
      expect(packedFonts, 2);
    });

    test('legacy shadow font list (no catalog) is still counted', () async {
      final String dbDir = p.join(src.path, 'db');
      final String fonts = p.join(src.path, 'custom_fonts');
      Directory(dbDir).createSync(recursive: true);
      await writeFile(p.join(fonts, 'Legacy.ttf'), 'FONT');
      await writeFile(p.join(fonts, '_tmp_999'), 'ORPHAN');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await db.setPref(
        'src:reader_ttu:custom_fonts',
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'Legacy',
            'path': p.join(fonts, 'Legacy.ttf'),
            'enabled': true,
          },
        ]),
      );
      final BackupService service = BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
        fontsRootDirectory: fonts,
      );
      final BackupContentSummary summary = await service.summarizeLiveContent();
      await db.close();
      expect(summary.countFor(BackupCategory.fonts), 1);
    });

    test('no catalog + no legacy list → zero fonts (orphans do not count)',
        () async {
      final String dbDir = p.join(src.path, 'db');
      final String fonts = p.join(src.path, 'custom_fonts');
      Directory(dbDir).createSync(recursive: true);
      await writeFile(p.join(fonts, '_tmp_1'), 'ORPHAN');
      await writeFile(p.join(fonts, 'strays.ttf'), 'ORPHAN');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      final BackupService service = BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
        fontsRootDirectory: fonts,
      );
      final BackupContentSummary summary = await service.summarizeLiveContent();
      await db.close();
      expect(summary.countFor(BackupCategory.fonts), 0);
    });
  });

  group('per-video export selection (videoKeys)', () {
    /// Lays out three local videos (A/B/C) and returns the service + db.
    Future<({BackupService service, HibikiDatabase db})>
        buildThreeVideos() async {
      final String dbDir = p.join(src.path, 'db');
      final String videos = p.join(src.path, 'external_videos');
      Directory(dbDir).createSync(recursive: true);
      await writeFile(p.join(videos, 'A.mp4'), 'VID-A');
      await writeFile(p.join(videos, 'B.mp4'), 'VID-B');
      await writeFile(p.join(videos, 'C.mp4'), 'VID-C');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      for (final String k in <String>['A', 'B', 'C']) {
        await db.upsertVideoBook(VideoBooksCompanion.insert(
          bookUid: 'video/$k',
          title: 'Video $k',
          videoPath: p.join(videos, '$k.mp4'),
        ));
      }
      final BackupService service = BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
      );
      return (service: service, db: db);
    }

    test('videoKeys packs only selected files AND strips other rows', () async {
      final ({BackupService service, HibikiDatabase db}) built =
          await buildThreeVideos();
      final String zip = p.join(src.path, 'videos.zip');
      final BackupMeta meta = await built.service.createBackup(
        zip,
        videoKeys: <String>{'video/A', 'video/C'},
      );
      await built.db.close();

      final Archive archive = await readZip(zip);
      final List<String> videoNames = archive.files
          .where((ArchiveFile f) => f.isFile && f.name.startsWith('videos/'))
          .map((ArchiveFile f) => f.name)
          .toList();
      // Exactly the two selected videos' files travel.
      expect(videoNames.length, 2);
      expect(videoNames.any((String n) => n.contains('A')), isTrue);
      expect(videoNames.any((String n) => n.contains('C')), isTrue);
      expect(videoNames.any((String n) => n.contains('B')), isFalse);

      // The deselected video's DB row is stripped (no ghost video on restore).
      final HibikiDatabase exdb = await openBackupDb(zip, dst);
      final List<VideoBookRow> rows = await exdb.allVideoBooks();
      await exdb.close();
      expect(rows.map((VideoBookRow v) => v.bookUid).toSet(),
          <String>{'video/A', 'video/C'});
      // bookCount is honest to what travels (2 usable videos, 0 epub books).
      expect(meta.bookCount, 2);
    });

    test('null videoKeys exports every video (legacy full export)', () async {
      final ({BackupService service, HibikiDatabase db}) built =
          await buildThreeVideos();
      final String zip = p.join(src.path, 'videos_all.zip');
      final BackupMeta meta = await built.service.createBackup(zip);
      await built.db.close();

      final HibikiDatabase exdb = await openBackupDb(zip, dst);
      expect(await countRows(exdb, 'video_books'), 3);
      await exdb.close();
      expect(meta.bookCount, 3);
    });

    test('excluding the videos category strips every video row', () async {
      final ({BackupService service, HibikiDatabase db}) built =
          await buildThreeVideos();
      final String zip = p.join(src.path, 'no_videos.zip');
      final BackupMeta meta = await built.service.createBackup(
        zip,
        categories: BackupCategory.values.toSet()
          ..remove(BackupCategory.videos),
      );
      await built.db.close();

      final Archive archive = await readZip(zip);
      expect(
        archive.files.any((ArchiveFile f) => f.name.startsWith('videos/')),
        isFalse,
      );
      final HibikiDatabase exdb = await openBackupDb(zip, dst);
      expect(await countRows(exdb, 'video_books'), 0);
      await exdb.close();
      expect(meta.bookCount, 0);
    });
  });
}
