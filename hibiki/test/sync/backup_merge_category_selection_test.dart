import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A MERGE import now honours the import dialog's per-category selection
/// (previously merge ignored it and always merged everything). An unticked
/// category adds neither its DB rows nor its content files.
void main() {
  late Directory srcRoot;
  late Directory zipDir;

  setUp(() async {
    srcRoot = await Directory.systemTemp.createTemp('mgcat_src_');
    zipDir = await Directory.systemTemp.createTemp('mgcat_zip_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[srcRoot, zipDir]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  /// Builds a backup carrying one book + one reading-statistics row.
  Future<String> buildBackup() async {
    final String dbDir = p.join(srcRoot.path, 'support');
    final String books = p.join(srcRoot.path, 'documents', 'hoshi_books');
    Directory(dbDir).createSync(recursive: true);
    File(p.join(books, 'B1', 'text', 'ch0.html'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<html>hi</html>');
    final HibikiDatabase src = HibikiDatabase(dbDir);
    await src.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'B1',
      title: 'B1',
      epubPath: 'B1.epub',
      extractDir: p.join(books, 'B1'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: _now(),
    ));
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'B1',
      dateKey: '2026-01-01',
      charactersRead: 100,
      readingTimeMs: 6000,
      lastStatisticModified: 10,
    ));
    final String zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: dbDir,
      appVersion: '2.0.0',
      booksRootDirectory: books,
    ).exportBackup(zip);
    await src.close();
    return zip;
  }

  Future<int> countRows(HibikiDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) c FROM $table').getSingle())
          .data['c'] as int;

  test('unticking statistics skips stats rows but still merges books',
      () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('mgcat_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);

    // Every category EXCEPT statistics.
    final Set<BackupCategory> categories = BackupCategory.values.toSet()
      ..remove(BackupCategory.statistics);
    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDbDir,
      zipPath: zip,
      categories: categories,
      booksRootDirectory: p.join(curRoot.path, 'documents', 'hoshi_books'),
    );

    final HibikiDatabase cur = HibikiDatabase(curDbDir);
    addTearDown(cur.close);
    expect(await countRows(cur, 'epub_books'), 1, reason: 'books still merge');
    expect(await countRows(cur, 'reading_statistics'), 0,
        reason: 'statistics unticked → not merged');
  });

  test('unticking books skips book rows but still merges statistics', () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('mgcat_cur2_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);

    final Set<BackupCategory> categories = BackupCategory.values.toSet()
      ..remove(BackupCategory.books);
    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDbDir,
      zipPath: zip,
      categories: categories,
      booksRootDirectory: p.join(curRoot.path, 'documents', 'hoshi_books'),
    );

    final HibikiDatabase cur = HibikiDatabase(curDbDir);
    addTearDown(cur.close);
    expect(await countRows(cur, 'epub_books'), 0,
        reason: 'books unticked → not merged');
    expect(await countRows(cur, 'reading_statistics'), 1,
        reason: 'statistics still merge');
    // Book content files must NOT be copied when books is unticked.
    expect(
      File(p.join(curRoot.path, 'documents', 'hoshi_books', 'B1', 'text',
              'ch0.html'))
          .existsSync(),
      isFalse,
      reason: 'book content tree skipped when books unticked',
    );
  });

  test('null categories still merges everything (legacy full merge)', () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('mgcat_cur3_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);

    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDbDir,
      zipPath: zip,
      booksRootDirectory: p.join(curRoot.path, 'documents', 'hoshi_books'),
    );

    final HibikiDatabase cur = HibikiDatabase(curDbDir);
    addTearDown(cur.close);
    expect(await countRows(cur, 'epub_books'), 1);
    expect(await countRows(cur, 'reading_statistics'), 1);
  });
}
