import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Regression: deleting a book (shelf delete → `deleteEpubBook(tombstone:true)`)
/// then MERGE-importing an older backup that still contains it must NOT bring
/// the book back. `epub_books` / `audiobooks` / `audio_cues` already honoured
/// the tombstone, but `srt_books` (dedups on `uid`, not `book_key`) did not, so
/// the merge resurrected an ORPHAN srt row with no epub row — an "empty book"
/// on the shelf. The srt merge now honours the deleted book's `book_key`
/// tombstone too.
void main() {
  Future<String> makeBackupWithBook(Directory root) async {
    final String dbDir = p.join(root.path, 'support');
    final String books = p.join(root.path, 'documents', 'fushi_books');
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
    await src.into(src.srtBooks).insert(SrtBooksCompanion.insert(
          uid: 'srtbook_epub_B1',
          title: 'B1',
          srtPath: 'B1.srt',
          importedAt: _now(),
          bookKey: const Value('B1'),
        ));
    final String zip = p.join(root.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: dbDir,
      appVersion: '2.0.0',
      booksRootDirectory: books,
    ).createBackup(zip);
    await src.close();
    return zip;
  }

  test('deleted book is not resurrected (no orphan srt) on MERGE', () async {
    final Directory srcRoot =
        await Directory.systemTemp.createTemp('srtt_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String zip = await makeBackupWithBook(srcRoot);

    // Target device had the same book, then the user DELETED it from the shelf
    // (tombstone:true — the real reader_fushi_source delete path).
    final Directory curRoot =
        await Directory.systemTemp.createTemp('srtt_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    final FushiDatabase seed = FushiDatabase(curDbDir);
    await seed.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'B1',
      title: 'B1',
      epubPath: 'B1.epub',
      extractDir: p.join(curRoot.path, 'documents', 'fushi_books', 'B1'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: _now(),
    ));
    await seed.into(seed.srtBooks).insert(SrtBooksCompanion.insert(
          uid: 'srtbook_epub_B1',
          title: 'B1',
          srtPath: 'B1.srt',
          importedAt: _now(),
          bookKey: const Value('B1'),
        ));
    await seed.deleteEpubBook('B1', tombstone: true);
    await seed.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );

    final FushiDatabase cur = FushiDatabase(curDbDir);
    addTearDown(cur.close);
    final int epub = (await cur
            .customSelect(
                "SELECT COUNT(*) c FROM epub_books WHERE book_key='B1'")
            .getSingle())
        .data['c'] as int;
    final int srt = (await cur
            .customSelect(
                "SELECT COUNT(*) c FROM srt_books WHERE book_key='B1'")
            .getSingle())
        .data['c'] as int;
    expect(epub, 0, reason: 'deleted book epub must stay tombstoned');
    expect(srt, 0,
        reason:
            'deleted book srt must also stay tombstoned (no orphan/empty book)');
  });

  test('standalone srt (book_key empty) still merges', () async {
    // A tombstone for a DIFFERENT book must not block an unrelated standalone
    // srt whose book_key is empty.
    final Directory srcRoot =
        await Directory.systemTemp.createTemp('srts_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String srcDbDir = p.join(srcRoot.path, 'support');
    Directory(srcDbDir).createSync(recursive: true);
    final FushiDatabase src = FushiDatabase(srcDbDir);
    await src.into(src.srtBooks).insert(SrtBooksCompanion.insert(
          uid: 'standalone_srt',
          title: 'Standalone',
          srtPath: 's.srt',
          importedAt: _now(),
          // no bookKey -> defaults to ''
        ));
    final String zip = p.join(srcRoot.path, 'b.zip');
    await BackupService(db: src, dbDirectory: srcDbDir, appVersion: '2.0.0')
        .createBackup(zip);
    await src.close();

    final Directory curRoot =
        await Directory.systemTemp.createTemp('srts_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    final FushiDatabase seed = FushiDatabase(curDbDir);
    await seed.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Other',
      title: 'Other',
      epubPath: 'o.epub',
      extractDir: 'o',
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: _now(),
    ));
    await seed.deleteEpubBook('Other', tombstone: true); // unrelated tombstone
    await seed.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );

    final FushiDatabase cur = FushiDatabase(curDbDir);
    addTearDown(cur.close);
    final int srt = (await cur
            .customSelect(
                "SELECT COUNT(*) c FROM srt_books WHERE uid='standalone_srt'")
            .getSingle())
        .data['c'] as int;
    expect(srt, 1, reason: 'standalone srt (empty book_key) must still merge');
  });
}
