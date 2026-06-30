import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

/// Full-data backup: export packs the hoshi_books + audiobooks trees and the
/// db; import (on a DIFFERENT set of roots) restores the files AND rebases the
/// stored absolute paths so the books resolve on the new device. (Task 4 + 5.)
void main() {
  late Directory src; // source "device" app layout
  late Directory dst; // destination "device" app layout

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_src_');
    dst = await Directory.systemTemp.createTemp('bk_dst_');
  });
  tearDown(() async {
    for (final d in [src, dst]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<void> writeFile(String path, String content) async {
    final f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  test('export includes trees + meta roots; import restores files and rebases',
      () async {
    // ── SOURCE device layout ───────────────────────────────────────────────
    final String srcDbDir = p.join(src.path, 'db');
    final String srcBooks = p.join(src.path, 'hoshi_books');
    final String srcAudio = p.join(src.path, 'audiobooks');
    Directory(srcDbDir).createSync(recursive: true);

    // One book on disk + DB row pointing at source-absolute paths.
    await writeFile(p.join(srcBooks, 'Bk', 'original.epub'), 'EPUB-BYTES');
    await writeFile(p.join(srcBooks, 'Bk', 'item', 'ch1.xhtml'), '<p>hi</p>');
    await writeFile(p.join(srcBooks, 'Bk', 'cover.jpg'), 'COVER');
    // One audiobook on disk + DB row.
    await writeFile(p.join(srcAudio, 'h', 'a.mp3'), 'MP3');
    await writeFile(p.join(srcAudio, 'h', 'align.srt'), 'SRT');

    final srcDb = HibikiDatabase(srcDbDir);
    await srcDb.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Bk',
      title: 'Bk',
      epubPath: p.join(srcBooks, 'Bk', 'original.epub'),
      extractDir: p.join(srcBooks, 'Bk'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
      coverPath: Value(p.join(srcBooks, 'Bk', 'cover.jpg')),
    ));
    await srcDb.upsertAudiobook(AudiobooksCompanion.insert(
      bookKey: 'Bk',
      alignmentFormat: 'srt',
      alignmentPath: p.join(srcAudio, 'h', 'align.srt'),
      audioRoot: Value(p.join(srcAudio, 'h')),
      // Built via jsonEncode so Windows backslashes are escaped — mirrors how
      // the app persists audio paths.
      audioPathsJson: Value(jsonEncode([p.join(srcAudio, 'h', 'a.mp3')])),
    ));

    // ── Export ─────────────────────────────────────────────────────────────
    final service = BackupService(
      db: srcDb,
      dbDirectory: srcDbDir,
      appVersion: '1.0.0',
      booksRootDirectory: srcBooks,
      audiobooksRootDirectory: srcAudio,
    );
    final String zipPath = p.join(src.path, 'backup.zip');
    final meta = await service.exportBackup(zipPath);
    await srcDb.close();

    // Meta records the source roots; the zip carries both trees.
    expect(meta.booksRoot, srcBooks);
    expect(meta.audiobooksRoot, srcAudio);
    final input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeBuffer(input);
    expect(archive.findFile('hoshi_books/Bk/original.epub'), isNotNull);
    expect(archive.findFile('hoshi_books/Bk/cover.jpg'), isNotNull);
    expect(archive.findFile('audiobooks/h/a.mp3'), isNotNull);
    expect(archive.findFile('audiobooks/h/align.srt'), isNotNull);
    await input.close();

    // ── Import onto the DESTINATION device (different roots, fresh install) ──
    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'hoshi_books');
    final String dstAudio = p.join(dst.path, 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);

    await BackupService.importBackupFiles(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: dstBooks,
      audiobooksRootDirectory: dstAudio,
    );

    // Files landed under the destination roots.
    expect(File(p.join(dstBooks, 'Bk', 'original.epub')).existsSync(), isTrue);
    expect(File(p.join(dstBooks, 'Bk', 'cover.jpg')).existsSync(), isTrue);
    expect(File(p.join(dstAudio, 'h', 'a.mp3')).existsSync(), isTrue);
    expect(File(p.join(dstAudio, 'h', 'align.srt')).existsSync(), isTrue);

    // DB paths were rebased to the destination roots AND resolve on disk.
    final dstDb = HibikiDatabase(dstDbDir);
    try {
      final book = await dstDb.getEpubBook('Bk');
      expect(book!.epubPath, p.join(dstBooks, 'Bk', 'original.epub'));
      expect(book.extractDir, p.join(dstBooks, 'Bk'));
      expect(book.coverPath, p.join(dstBooks, 'Bk', 'cover.jpg'));
      expect(File(book.epubPath).existsSync(), isTrue,
          reason: 'rebased epubPath must resolve on the new device');

      final ab = await dstDb.getAudiobookByBookKey('Bk');
      expect(ab!.audioRoot, p.join(dstAudio, 'h'));
      expect(ab.alignmentPath, p.join(dstAudio, 'h', 'align.srt'));
      final List<dynamic> audioPaths =
          jsonDecode(ab.audioPathsJson!) as List<dynamic>;
      expect(audioPaths, [p.join(dstAudio, 'h', 'a.mp3')]);
    } finally {
      await dstDb.close();
    }
  });

  test(
      'atomic tree restore leaves the existing tree intact when the backup '
      'carries no files under that prefix', () async {
    // A db-only backup (no roots) must NOT wipe the destination's books tree.
    final String srcDbDir = p.join(src.path, 'db');
    Directory(srcDbDir).createSync(recursive: true);
    final srcDb = HibikiDatabase(srcDbDir);
    final zipPath = p.join(src.path, 'dbonly.zip');
    await BackupService(
      db: srcDb,
      dbDirectory: srcDbDir,
      appVersion: '1.0.0',
    ).exportBackup(zipPath);
    await srcDb.close();

    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'hoshi_books');
    Directory(dstDbDir).createSync(recursive: true);
    await writeFile(p.join(dstBooks, 'Existing', 'keep.epub'), 'KEEP');

    await BackupService.importBackupFiles(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: dstBooks,
    );

    expect(File(p.join(dstBooks, 'Existing', 'keep.epub')).existsSync(), isTrue,
        reason: 'empty-prefix backup must not delete the existing tree');
  });

  test(
      'import clears stale .import-old/.import-tmp leftovers from a prior '
      'crashed import (W1)', () async {
    // Make a real full backup with one book.
    final String srcDbDir = p.join(src.path, 'db');
    final String srcBooks = p.join(src.path, 'hoshi_books');
    Directory(srcDbDir).createSync(recursive: true);
    await writeFile(p.join(srcBooks, 'Bk', 'original.epub'), 'EPUB');
    final srcDb = HibikiDatabase(srcDbDir);
    await srcDb.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Bk',
      title: 'Bk',
      epubPath: p.join(srcBooks, 'Bk', 'original.epub'),
      extractDir: p.join(srcBooks, 'Bk'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));
    final zipPath = p.join(src.path, 'backup.zip');
    await BackupService(
      db: srcDb,
      dbDirectory: srcDbDir,
      appVersion: '1.0.0',
      booksRootDirectory: srcBooks,
    ).exportBackup(zipPath);
    await srcDb.close();

    // Destination has stale leftovers from a previously-crashed import.
    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'hoshi_books');
    Directory(dstDbDir).createSync(recursive: true);
    await writeFile(
        '$dstBooks.import-old${Platform.pathSeparator}junk.txt', 'x');
    await writeFile(
        '$dstBooks.import-tmp${Platform.pathSeparator}junk.txt', 'x');

    await BackupService.importBackupFiles(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: dstBooks,
    );

    // Book restored; both stale leftover dirs are gone.
    expect(File(p.join(dstBooks, 'Bk', 'original.epub')).existsSync(), isTrue);
    expect(Directory('$dstBooks.import-old').existsSync(), isFalse);
    expect(Directory('$dstBooks.import-tmp').existsSync(), isFalse);
  });
}
