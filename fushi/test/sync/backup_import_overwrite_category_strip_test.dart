import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Overwrite import now honours per-category selection for the DB-content
/// categories (books / statistics / progress) that ride the whole-DB blob:
/// unticking one strips its rows from the swapped-in DB so it does not land on
/// this device. (The file-tree categories were already gated by skipping their
/// restore.)
void main() {
  late Directory srcRoot;
  late Directory zipDir;

  setUp(() async {
    srcRoot = await Directory.systemTemp.createTemp('ovcat_src_');
    zipDir = await Directory.systemTemp.createTemp('ovcat_zip_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[srcRoot, zipDir]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<String> buildBackup() async {
    final String dbDir = p.join(srcRoot.path, 'support');
    final String books = p.join(srcRoot.path, 'documents', 'fushi_books');
    Directory(dbDir).createSync(recursive: true);
    File(p.join(books, 'B1', 'text', 'ch0.html'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<html>hi</html>');
    final FushiDatabase src = FushiDatabase(dbDir);
    await src.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'B1',
      title: 'B1',
      epubPath: 'B1.epub',
      extractDir: p.join(books, 'B1'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: _now(),
    ));
    // v82：reader_positions 键 = epub_books.uid（insertEpubBook 自动生成）。
    final String b1Uid = (await src.resolveEpubBookUid('B1'))!;
    await src.upsertReaderPosition(ReaderPositionsCompanion.insert(
        bookUid: b1Uid, sectionIndex: 0, normCharOffset: 100, updatedAt: 1));
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
    ).createBackup(zip);
    await src.close();
    return zip;
  }

  Future<int> countRows(FushiDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) c FROM $table').getSingle())
          .data['c'] as int;

  Future<FushiDatabase> importInto(String zip, Set<BackupCategory> cats,
      {required Directory curRoot}) async {
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    await BackupService.restoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
      importSettings: true,
      categories: cats,
      booksRootDirectory: p.join(curRoot.path, 'documents', 'fushi_books'),
    );
    return FushiDatabase(curDbDir);
  }

  test('untick books → no book rows or content on overwrite', () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('ovcat_c1_');
    addTearDown(() => cleanupTempDir(curRoot));
    final FushiDatabase cur = await importInto(
        zip, BackupCategory.values.toSet()..remove(BackupCategory.books),
        curRoot: curRoot);
    addTearDown(cur.close);
    expect(await countRows(cur, 'epub_books'), 0);
    // statistics unaffected (still ticked).
    expect(await countRows(cur, 'reading_statistics'), 1);
    expect(
      File(p.join(curRoot.path, 'documents', 'fushi_books', 'B1', 'text',
              'ch0.html'))
          .existsSync(),
      isFalse,
      reason: 'book content tree skipped when books unticked',
    );
  });

  test('untick statistics → no stats rows on overwrite', () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('ovcat_c2_');
    addTearDown(() => cleanupTempDir(curRoot));
    final FushiDatabase cur = await importInto(
        zip, BackupCategory.values.toSet()..remove(BackupCategory.statistics),
        curRoot: curRoot);
    addTearDown(cur.close);
    expect(await countRows(cur, 'reading_statistics'), 0);
    expect(await countRows(cur, 'epub_books'), 1,
        reason: 'books still restore');
  });

  test('untick progress → no reader positions on overwrite', () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('ovcat_c3_');
    addTearDown(() => cleanupTempDir(curRoot));
    final FushiDatabase cur = await importInto(
        zip, BackupCategory.values.toSet()..remove(BackupCategory.progress),
        curRoot: curRoot);
    addTearDown(cur.close);
    expect(await countRows(cur, 'reader_positions'), 0);
    expect(await countRows(cur, 'epub_books'), 1);
  });

  test('all ticked → everything restores (legacy overwrite)', () async {
    final String zip = await buildBackup();
    final Directory curRoot =
        await Directory.systemTemp.createTemp('ovcat_c4_');
    addTearDown(() => cleanupTempDir(curRoot));
    final FushiDatabase cur =
        await importInto(zip, BackupCategory.values.toSet(), curRoot: curRoot);
    addTearDown(cur.close);
    expect(await countRows(cur, 'epub_books'), 1);
    expect(await countRows(cur, 'reading_statistics'), 1);
    expect(await countRows(cur, 'reader_positions'), 1);
  });
}
