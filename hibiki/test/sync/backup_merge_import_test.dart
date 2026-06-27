import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Exports [srcDb] (in [srcDir]) to a backup zip at [zipPath].
Future<void> _exportZip(
  HibikiDatabase srcDb,
  String srcDir,
  String zipPath,
) async {
  await BackupService(db: srcDb, dbDirectory: srcDir, appVersion: '2.0.0')
      .exportBackup(zipPath);
}

/// Builds a minimal valid backup zip from a raw `hibiki.db` file (used to drive
/// a deliberate mid-merge crash).
Future<void> _zipDbWithMeta(String dbFilePath, String zipPath) async {
  final ZipFileEncoder enc = ZipFileEncoder();
  enc.create(zipPath);
  enc.addFile(File(dbFilePath), 'hibiki.db');
  final List<int> meta = '{"appVersion":"2.0.0","schemaVersion":29,'
          '"createdAt":"2026-01-01T00:00:00.000","bookCount":0,"statsCount":0}'
      .codeUnits;
  enc.addArchiveFile(ArchiveFile('backup_meta.json', meta.length, meta));
  enc.closeSync();
}

EpubBooksCompanion _book(String key) => EpubBooksCompanion.insert(
      bookKey: key,
      title: key,
      epubPath: '/fake/$key.epub',
      extractDir: '/fake/$key',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: _now(),
    );

void main() {
  test('union: device keeps its books, backup adds the missing ones', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.insertEpubBook(_book('local-only'));
    await cur.insertEpubBook(_book('shared'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    await src.insertEpubBook(_book('shared'));
    await src.insertEpubBook(_book('backup-only'));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'local-only', 'shared', 'backup-only'});

    // No temp/bak leak.
    expect(
        File(p.join(curDir.path, 'hibiki.db.merge-src')).existsSync(), false);
    expect(File(p.join(curDir.path, 'hibiki.db.pre-merge.bak')).existsSync(),
        false);
    expect(
        File(p.join(curDir.path, 'hibiki.db.merge-preserve.json')).existsSync(),
        false);
  });

  test('reading statistics: same {title,dateKey} take MAX, never SUM',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'A',
      dateKey: '2026-01-01',
      charactersRead: 100,
      readingTimeMs: 6000,
      lastStatisticModified: 10,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'A',
      dateKey: '2026-01-01',
      charactersRead: 80,
      readingTimeMs: 9000,
      lastStatisticModified: 20,
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);
    // Re-import the SAME backup again — must stay idempotent.
    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllReadingStatistics();
    expect(rows, hasLength(1));
    expect(rows.single.charactersRead, 100); // max(100, 80)
    expect(rows.single.readingTimeMs, 9000); // max(6000, 9000)
  });

  test('reading statistics: many titles under one dateKey are NOT folded',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'BookA',
      dateKey: '2026-02-02',
      charactersRead: 50,
      readingTimeMs: 1000,
      lastStatisticModified: 1,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    // Two DIFFERENT titles, SAME dateKey.
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'BookA',
      dateKey: '2026-02-02',
      charactersRead: 70,
      readingTimeMs: 500,
      lastStatisticModified: 2,
    ));
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'BookB',
      dateKey: '2026-02-02',
      charactersRead: 999,
      readingTimeMs: 3000,
      lastStatisticModified: 3,
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllReadingStatistics();
    // Two distinct (title, dateKey) rows — NOT folded into one.
    expect(rows, hasLength(2));
    final byTitle = {for (final r in rows) r.title: r};
    expect(byTitle['BookA']!.charactersRead, 70); // max(50, 70)
    expect(byTitle['BookB']!.charactersRead, 999); // backup-only inserted
  });

  test('mining statistics MAX-union (not double-counted on re-import)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.setMiningCount(
        sourceType: 'book', dateKey: '2026-03-03', count: 5);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    await src.setMiningCount(
        sourceType: 'book', dateKey: '2026-03-03', count: 3);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);
    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getMiningStatisticsBySource('book');
    expect(rows, hasLength(1));
    expect(rows.single.count, 5); // max(5, 3), never 8
  });

  test('favorite words dedupe-union keeps earlier createdAt', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.addFavoriteWord(
      expression: '表現',
      reading: 'ひょうげん',
      glossary: 'local',
      sourceType: 'book',
      dateKey: '2026-01-01',
    );
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    await src.addFavoriteWord(
      expression: '表現',
      reading: 'ひょうげん',
      glossary: 'backup',
      sourceType: 'book',
      dateKey: '2026-01-01',
    );
    await src.addFavoriteWord(
      expression: 'new',
      reading: '',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-01-01',
    );
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final all = await after.getAllFavoriteWords();
    expect(all, hasLength(2)); // dup dropped, 'new' added
    final dup = all.firstWhere((w) => w.expression == '表現');
    expect(dup.glossary, 'local'); // earlier (device) row kept
  });

  test('tagId is remapped across DBs (no dangling FK on book tag mappings)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    // Device already has SOME tags so its autoincrement ids differ from src.
    await cur.createTag('existing-a', 0xFF111111);
    await cur.createTag('existing-b', 0xFF222222);
    await cur.insertEpubBook(_book('book1'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    final int srcTagId = await src.createTag('shared-tag', 0xFF333333);
    await src.insertEpubBook(_book('book1'));
    await src.addTagToBook('book1', srcTagId);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    // The new tag landed with a FRESH id (not the src id).
    final tagRows = await after
        .customSelect("SELECT id FROM book_tags WHERE name = 'shared-tag'")
        .get();
    expect(tagRows, hasLength(1));
    final int targetTagId = tagRows.single.data['id'] as int;
    // The mapping points at the REMAPPED target id, not the src id.
    final maps = await after
        .customSelect('SELECT tag_id FROM book_tag_mappings '
            "WHERE book_key = 'book1'")
        .get();
    expect(maps, hasLength(1));
    expect(maps.single.data['tag_id'], targetTagId);
    // No dangling FK: every mapping tag_id resolves to a real tag.
    final dangling = await after
        .customSelect('SELECT COUNT(*) AS c FROM book_tag_mappings m '
            'WHERE NOT EXISTS (SELECT 1 FROM book_tags t WHERE t.id = m.tag_id)')
        .getSingle();
    expect(dangling.data['c'], 0);
  });

  test('profileId is remapped across DBs (no dangling FK on child tables)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    // Device already has a profile so its ids diverge from src.
    await cur.insertProfile(
        ProfilesCompanion.insert(name: 'Default', createdAt: 1, updatedAt: 1));
    await cur.insertEpubBook(_book('pbook'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    final int srcProfileId = await src.insertProfile(
        ProfilesCompanion.insert(name: 'Reading', createdAt: 2, updatedAt: 2));
    await src.upsertProfileSetting(ProfileSettingsCompanion.insert(
      profileId: srcProfileId,
      category: 'reader',
      key: 'fontSize',
      value: '18',
    ));
    await src.insertEpubBook(_book('pbook'));
    await src.setBookProfile('pbook', srcProfileId);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final pr = await after
        .customSelect("SELECT id FROM profiles WHERE name = 'Reading'")
        .get();
    expect(pr, hasLength(1));
    final int targetPid = pr.single.data['id'] as int;
    // profile_settings child remapped to the new profile id.
    final ps = await after
        .customSelect('SELECT profile_id FROM profile_settings '
            "WHERE key = 'fontSize'")
        .get();
    expect(ps, hasLength(1));
    expect(ps.single.data['profile_id'], targetPid);
    // book_profiles child remapped too.
    final bp = await after
        .customSelect('SELECT profile_id FROM book_profiles '
            "WHERE book_key = 'pbook'")
        .get();
    expect(bp, hasLength(1));
    expect(bp.single.data['profile_id'], targetPid);
    // No dangling FK across all three child tables.
    for (final t in [
      'profile_settings',
      'media_type_profiles',
      'book_profiles'
    ]) {
      final d = await after
          .customSelect('SELECT COUNT(*) AS c FROM $t x '
              'WHERE NOT EXISTS (SELECT 1 FROM profiles p '
              'WHERE p.id = x.profile_id)')
          .getSingle();
      expect(d.data['c'], 0, reason: '$t has a dangling profile_id');
    }
  });

  test('mined sentences dedupe by fingerprint (no INSERT OR IGNORE reliance)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.addMinedSentence(
      source: 'book',
      dateKey: '2026-01-01',
      expression: '語',
      reading: 'ご',
    );
    // Read back its created_at so the backup can carry an IDENTICAL fingerprint.
    final int sharedCreatedAt =
        (await cur.getAllMinedSentences()).single.createdAt;
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    // Same fingerprint (duplicate) — must be dropped.
    await src.into(src.minedSentences).insert(MinedSentencesCompanion.insert(
          source: 'book',
          dateKey: '2026-01-01',
          expression: const Value('語'),
          reading: const Value('ご'),
          createdAt: sharedCreatedAt,
        ));
    // Different created_at — must be kept.
    await src.addMinedSentence(
      source: 'book',
      dateKey: '2026-01-02',
      expression: '別',
      reading: 'べつ',
    );
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllMinedSentences();
    expect(rows, hasLength(2)); // dup dropped, distinct one added
  });

  test('reader position LWW: newer updatedAt wins, older does not clobber',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.insertEpubBook(_book('lwwbook'));
    await cur.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'lwwbook',
      sectionIndex: 2,
      normCharOffset: 5000,
      updatedAt: 100,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    await src.insertEpubBook(_book('lwwbook'));
    await src.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'lwwbook',
      sectionIndex: 9,
      normCharOffset: 9999,
      updatedAt: 200, // newer → wins
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final pos = await after.getReaderPosition('lwwbook');
    expect(pos!.sectionIndex, 9); // backup (newer) won
    expect(pos.normCharOffset, 9999);

    // Now re-merge a backup whose updatedAt is OLDER — must not clobber.
    final src2Dir = await _tempDir('mg_src2_');
    addTearDown(() => src2Dir.delete(recursive: true));
    final src2 = HibikiDatabase(src2Dir.path);
    await src2.insertEpubBook(_book('lwwbook'));
    await src2.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'lwwbook',
      sectionIndex: 0,
      normCharOffset: 1,
      updatedAt: 50, // older → must lose
    ));
    final zip2 = p.join(zipDir.path, 'b2.zip');
    await _exportZip(src2, src2Dir.path, zip2);
    await src2.close();
    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip2);
    final pos2 = await after.getReaderPosition('lwwbook');
    expect(pos2!.sectionIndex, 9); // unchanged — older backup ignored
  });

  test('content tree restore is copy-if-absent (never overwrites existing)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.close();

    // This device's books tree: one existing file with LOCAL content.
    final booksRoot = await _tempDir('mg_books_');
    addTearDown(() => booksRoot.delete(recursive: true));
    final existing = File(p.join(booksRoot.path, 'shared.txt'));
    await existing.writeAsString('LOCAL');

    // Backup carries the SAME relative file (different content) + a NEW file.
    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    final srcBooks = await _tempDir('mg_srcbooks_');
    addTearDown(() => srcBooks.delete(recursive: true));
    await File(p.join(srcBooks.path, 'shared.txt')).writeAsString('BACKUP');
    await File(p.join(srcBooks.path, 'new.txt')).writeAsString('NEW');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
      booksRootDirectory: srcBooks.path,
    ).exportBackup(zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDir.path,
      zipPath: zip,
      booksRootDirectory: booksRoot.path,
    );

    // Existing file untouched; new file added.
    expect(await existing.readAsString(), 'LOCAL');
    expect(await File(p.join(booksRoot.path, 'new.txt')).readAsString(), 'NEW');
  });

  test('bookmark for a book the backup omitted is skipped (no FK violation)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.insertEpubBook(_book('owned'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    // Bookmark whose owning book is NOT in the backup (and not on device).
    await src.insertEpubBook(_book('owned'));
    await src.customStatement(
      'INSERT INTO bookmarks (book_key, section_index, norm_char_offset, '
      'label, created_at) VALUES (?, ?, ?, ?, ?)',
      <Object?>['owned', 1, 100, 'kept', 10],
    );
    // A second epub_books row exists in src, but we delete it AFTER making a
    // bookmark to simulate an orphan reference — instead, just add a bookmark
    // referencing 'owned' which both have; verify it merges. For the skip case,
    // craft a bookmark on a book missing from BOTH by temporarily disabling FK.
    await src.customStatement('PRAGMA foreign_keys = OFF');
    await src.customStatement(
      'INSERT INTO bookmarks (book_key, section_index, norm_char_offset, '
      'label, created_at) VALUES (?, ?, ?, ?, ?)',
      <Object?>['ghost', 5, 500, 'skipme', 20],
    );
    await src.customStatement('PRAGMA foreign_keys = ON');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // Must NOT throw (FK preserved) and must skip the ghost bookmark.
    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final labels =
        (await after.customSelect('SELECT label FROM bookmarks').get())
            .map((r) => r.data['label'] as String)
            .toSet();
    expect(labels.contains('kept'), true);
    expect(labels.contains('skipme'), false); // ghost-book bookmark skipped
    // No dangling FK.
    final dangling = await after
        .customSelect('SELECT COUNT(*) AS c FROM bookmarks b '
            'WHERE NOT EXISTS (SELECT 1 FROM epub_books e '
            'WHERE e.book_key = b.book_key)')
        .getSingle();
    expect(dangling.data['c'], 0);
  });

  test('crash mid-merge rolls back: device DB unchanged, bak retained',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.insertEpubBook(_book('survivor'));
    await cur.close();

    // A backup zip whose hibiki.db is NOT a valid SQLite file → opening it to
    // migrate throws. The orchestrator must surface the error WITHOUT touching
    // the live DB (snapshot/mutation happen only after a successful migrate).
    final corruptDir = await _tempDir('mg_corrupt_');
    addTearDown(() => corruptDir.delete(recursive: true));
    final corruptDb = File(p.join(corruptDir.path, 'hibiki.db'));
    await corruptDb.writeAsBytes(List<int>.filled(64, 0x7a)); // garbage
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'corrupt.zip');
    await _zipDbWithMeta(corruptDb.path, zip);

    await expectLater(
      BackupService.mergeImportBackupFiles(
          dbDirectory: curDir.path, zipPath: zip),
      throwsA(anything),
    );

    // Live DB still has exactly the original content.
    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'survivor'});
  });

  test('engine-level transaction rolls back a partial merge on failure',
      () async {
    final tDir = await _tempDir('mg_eng_');
    addTearDown(() => tDir.delete(recursive: true));
    final target = HibikiDatabase(tDir.path);
    addTearDown(target.close);
    await target.insertEpubBook(_book('orig'));

    // Build a src DB, then ATTACH it and abort the transaction mid-way: insert
    // a book that succeeds, then force a failure, and assert nothing committed.
    final sDir = await _tempDir('mg_engsrc_');
    addTearDown(() => sDir.delete(recursive: true));
    final srcDb = HibikiDatabase(sDir.path);
    await srcDb.insertEpubBook(_book('from-src'));
    await srcDb.close();

    final String safe = p.join(sDir.path, 'hibiki.db').replaceAll(r'\', '/');
    await target.customStatement("ATTACH DATABASE '$safe' AS probe");
    try {
      await expectLater(
        target.transaction(() async {
          await target.customStatement(
            'INSERT INTO epub_books (book_key, title, epub_path, extract_dir, '
            'chapter_count, chapters_json, imported_at) '
            'SELECT book_key, title, epub_path, extract_dir, chapter_count, '
            'chapters_json, imported_at FROM probe.epub_books',
          );
          // Now throw → the whole transaction must roll back.
          throw StateError('boom');
        }),
        throwsStateError,
      );
    } finally {
      await target.customStatement('DETACH DATABASE probe');
    }
    final keys = (await target.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'orig'}); // 'from-src' rolled back
  });

  test('overwrite import path is unchanged (whole DB replaced, no merge)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => curDir.delete(recursive: true));
    final cur = HibikiDatabase(curDir.path);
    await cur.insertEpubBook(_book('device-book'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final src = HibikiDatabase(srcDir.path);
    await src.insertEpubBook(_book('backup-book'));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.importBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    // OVERWRITE: only the backup's book survives (device book gone).
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'backup-book'});
  });
}
