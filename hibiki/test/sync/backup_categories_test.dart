import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'sync_settings_schema_source_corpus.dart';
import 'temp_dir_cleanup.dart';

/// TODO-106/TODO-249: the export dialog lets the user pick which sidecar trees
/// travel in the backup. [BackupService.createBackup]'s [categories] param
/// is the contract: a null set packs everything (legacy all-in export); a
/// non-null set packs ONLY the listed trees. The db is always packed.
void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_cat_src_');
    dst = await Directory.systemTemp.createTemp('bk_cat_dst_');
  });
  tearDown(() async {
    for (final d in [src, dst]) {
      try {
        if (d.existsSync()) await cleanupTempDir(d);
      } on PathNotFoundException {
        // Windows recursive cleanup can race with already-removed temp paths.
      }
    }
  });

  Future<void> writeFile(String path, String content) async {
    final f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  /// Lays out a source "device" with all optional trees populated, plus a
  /// db row that gives the dictionary tree real metadata (so
  /// `_hasCompleteDictionaryResources` accepts it). Returns the built service +
  /// roots so each test can export with a different category set.
  Future<({BackupService service, FushiDatabase db, String dictRoot})>
      buildFullSource() async {
    final String dbDir = p.join(src.path, 'db');
    final String books = p.join(src.path, 'hoshi_books');
    final String audio = p.join(src.path, 'audiobooks');
    final String fonts = p.join(src.path, 'custom_fonts');
    final String dict = p.join(src.path, 'dictionaryResources');
    final String videos = p.join(src.path, 'external_videos');
    Directory(dbDir).createSync(recursive: true);

    await writeFile(p.join(books, 'Bk', 'original.epub'), 'EPUB');
    await writeFile(p.join(audio, 'h', 'a.mp3'), 'MP3');
    await writeFile(p.join(fonts, 'MyFont.ttf'), 'FONT');
    await writeFile(p.join(dict, 'JMdict', 'index.bin'), 'IDX');
    await writeFile(p.join(videos, 'Film.mp4'), 'MP4');
    await writeFile(p.join(videos, 'Episode1.mkv'), 'EP1');

    final db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Bk',
      title: 'Bk',
      epubPath: p.join(books, 'Bk', 'original.epub'),
      extractDir: p.join(books, 'Bk'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));
    await db.upsertAudiobook(AudiobooksCompanion.insert(
      bookKey: 'Bk',
      alignmentFormat: 'srt',
      alignmentPath: p.join(audio, 'h', 'align.srt'),
      audioRoot: Value(p.join(audio, 'h')),
    ));
    // A dictionary meta row whose resource dir exists → counts as "complete".
    await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: 'JMdict',
      formatKey: 'yomitan',
      order: 0,
    ));
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/film',
      title: 'Film',
      videoPath: p.join(videos, 'Film.mp4'),
      playlistJson: Value(jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'title': 'Episode 1',
          'path': p.join(videos, 'Episode1.mkv'),
        },
      ])),
    ));
    // The font catalog references MyFont.ttf: the export packs (and counts)
    // ONLY catalog-referenced files, so without this the font would be treated
    // as an orphan and skipped.
    await db.setPref(
      'src:reader_ttu:font_catalog',
      jsonEncode(<String, Object?>{
        'version': 1,
        'fonts': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'f1',
            'name': 'MyFont',
            'path': p.join(fonts, 'MyFont.ttf'),
          },
        ],
      }),
    );

    final service = BackupService(
      db: db,
      dbDirectory: dbDir,
      appVersion: '1.0.0',
      dictionaryResourceDirectory: dict,
      booksRootDirectory: books,
      audiobooksRootDirectory: audio,
      fontsRootDirectory: fonts,
    );
    return (service: service, db: db, dictRoot: dict);
  }

  Future<Archive> readZip(String zipPath) async {
    final input = InputFileStream(zipPath);
    try {
      return ZipDecoder().decodeBuffer(input);
    } finally {
      await input.close();
    }
  }

  /// Extracts the packed `fushi.db` from [zipPath] into a fresh dir under [into]
  /// and opens it, so a test can assert on the exported DB blob's rows directly.
  Future<FushiDatabase> openBackupDb(String zipPath, Directory into) async {
    final Archive archive = await readZip(zipPath);
    final ArchiveFile dbFile = archive.findFile('fushi.db')!;
    final Directory dir = Directory(p.join(into.path, 'exdb'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'fushi.db'))
        .writeAsBytesSync(dbFile.content as List<int>);
    return FushiDatabase(dir.path);
  }

  Future<int> countRows(FushiDatabase db, String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.data['c'] as int;
  }

  Future<({BackupService service, FushiDatabase db, String dbDir})>
      buildDataSource() async {
    final String dbDir = p.join(src.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Bk',
      title: 'Bk',
      epubPath: 'x',
      extractDir: 'y',
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));
    await db.upsertReaderPosition(ReaderPositionsCompanion.insert(
        bookKey: 'Bk', sectionIndex: 0, normCharOffset: 100, updatedAt: 1));
    await db.into(db.bookmarks).insert(BookmarksCompanion.insert(
        bookKey: 'Bk',
        sectionIndex: 0,
        normCharOffset: 100,
        label: 'bm',
        createdAt: 1));
    await db.setPref('audiobook_pos_Bk', '12345');
    await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
        title: 'Bk',
        dateKey: '2026-01-01',
        charactersRead: 10,
        readingTimeMs: 1000,
        lastStatisticModified: 1));
    await db.setPref('theme_mode', 'dark');
    await db.setPref('favorite_sentences', '[]');
    await db.setPref('local_audio_dbs', '[]');
    final int pid = await db.insertProfile(
        ProfilesCompanion.insert(name: 'P1', createdAt: 1, updatedAt: 1));
    await db.upsertProfileSetting(ProfileSettingsCompanion.insert(
        profileId: pid, category: 'reader', key: 'k', value: 'v'));
    final BackupService service =
        BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');
    return (service: service, db: db, dbDir: dbDir);
  }

  Set<BackupCategory> allExcept(BackupCategory c) =>
      BackupCategory.values.toSet()..remove(c);

  test('null categories packs every tree (legacy all-in export)', () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'all.zip');
    final meta = await built.service.createBackup(zip);
    await built.db.close();

    final archive = await readZip(zip);
    expect(archive.findFile('hoshi_books/Bk/original.epub'), isNotNull);
    expect(archive.findFile('audiobooks/h/a.mp3'), isNotNull);
    expect(archive.findFile('custom_fonts/MyFont.ttf'), isNotNull);
    expect(archive.findFile('dictionaryResources/JMdict/index.bin'), isNotNull);
    expect(
      archive.files.any((ArchiveFile f) =>
          f.isFile && f.name.startsWith('videos/') && f.name.endsWith('.mp4')),
      isTrue,
    );
    expect(archive.findFile('fushi.db'), isNotNull);
    // Meta records every packed tree's root.
    expect(meta.booksRoot, isNotNull);
    expect(meta.audiobooksRoot, isNotNull);
    expect(meta.fontsRoot, isNotNull);
  });

  test('selecting only books packs books + db, excludes the other trees',
      () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'books_only.zip');
    final meta = await built.service.createBackup(
      zip,
      categories: {BackupCategory.books},
    );
    await built.db.close();

    final archive = await readZip(zip);
    expect(archive.findFile('fushi.db'), isNotNull,
        reason: 'db is always packed');
    expect(archive.findFile('hoshi_books/Bk/original.epub'), isNotNull);
    // Unselected trees are absent.
    expect(archive.findFile('audiobooks/h/a.mp3'), isNull);
    expect(archive.findFile('custom_fonts/MyFont.ttf'), isNull);
    expect(archive.findFile('dictionaryResources/JMdict/index.bin'), isNull);
    expect(
      archive.files.any((ArchiveFile f) => f.name.startsWith('videos/')),
      isFalse,
    );
    // Meta only records the packed tree's root; omitted trees are null.
    expect(meta.booksRoot, isNotNull);
    expect(meta.audiobooksRoot, isNull);
    expect(meta.fontsRoot, isNull);
  });

  test('empty category set packs db only (every tree excluded)', () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'db_only.zip');
    await built.service.createBackup(zip, categories: <BackupCategory>{});
    await built.db.close();

    final archive = await readZip(zip);
    expect(archive.findFile('fushi.db'), isNotNull);
    expect(archive.findFile('hoshi_books/Bk/original.epub'), isNull);
    expect(archive.findFile('audiobooks/h/a.mp3'), isNull);
    expect(archive.findFile('custom_fonts/MyFont.ttf'), isNull);
    expect(archive.findFile('dictionaryResources/JMdict/index.bin'), isNull);
    expect(
      archive.files.any((ArchiveFile f) => f.name.startsWith('videos/')),
      isFalse,
    );
  });

  test('selecting videos packs video files and import rewrites videoPath',
      () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'videos.zip');
    await built.service.createBackup(zip, categories: {BackupCategory.videos});
    await built.db.close();

    final Archive archive = await readZip(zip);
    final ArchiveFile videoEntry = archive.files.singleWhere(
      (ArchiveFile f) =>
          f.isFile && f.name.startsWith('videos/') && f.name.endsWith('.mp4'),
    );
    final ArchiveFile playlistEntry = archive.files.singleWhere(
      (ArchiveFile f) =>
          f.isFile && f.name.startsWith('videos/') && f.name.endsWith('.mkv'),
    );
    expect(String.fromCharCodes(videoEntry.content as List<int>), 'MP4');
    expect(String.fromCharCodes(playlistEntry.content as List<int>), 'EP1');
    expect(archive.findFile('hoshi_books/Bk/original.epub'), isNull);
    expect(archive.findFile('audiobooks/h/a.mp3'), isNull);

    final String dstDbDir = p.join(dst.path, 'db');
    final String dstVideos = p.join(dst.path, 'videos');
    Directory(dstDbDir).createSync(recursive: true);

    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zip,
      videosRootDirectory: dstVideos,
    );

    final FushiDatabase restored = FushiDatabase(dstDbDir);
    try {
      final VideoBookRow? row =
          await restored.getVideoBookByBookUid('video/film');
      expect(row, isNotNull);
      expect(row!.videoPath, startsWith(dstVideos));
      expect(File(row.videoPath).readAsStringSync(), 'MP4');
      final List<dynamic> playlist =
          jsonDecode(row.playlistJson!) as List<dynamic>;
      final String episodePath =
          (playlist.single as Map<String, dynamic>)['path'] as String;
      expect(episodePath, startsWith(dstVideos));
      expect(File(episodePath).readAsStringSync(), 'EP1');
    } finally {
      await restored.close();
    }
  });

  test(
      'importing a partial (books-only) backup leaves the existing audio tree '
      'intact and does not crash', () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'books_only.zip');
    await built.service.createBackup(zip, categories: {BackupCategory.books});
    await built.db.close();

    // Destination already has an audiobook tree that must survive a books-only
    // restore (the partial backup carries no audio prefix).
    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'hoshi_books');
    final String dstAudio = p.join(dst.path, 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);
    await writeFile(p.join(dstAudio, 'keep', 'kept.mp3'), 'KEEP');

    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zip,
      booksRootDirectory: dstBooks,
      audiobooksRootDirectory: dstAudio,
    );

    expect(File(p.join(dstBooks, 'Bk', 'original.epub')).existsSync(), isTrue,
        reason: 'books tree was in the partial backup → restored');
    expect(File(p.join(dstAudio, 'keep', 'kept.mp3')).existsSync(), isTrue,
        reason: 'audio tree absent from backup → existing tree untouched');
  });
  test(
      'BackupCategory enumerates the six sidecar trees plus the four DB-only '
      'data categories (db is never itself a category)', () {
    expect(BackupCategory.values.toSet(), <BackupCategory>{
      BackupCategory.dictionary,
      BackupCategory.books,
      BackupCategory.audiobooks,
      BackupCategory.fonts,
      BackupCategory.videos,
      BackupCategory.localAudio,
      BackupCategory.progress,
      BackupCategory.statistics,
      BackupCategory.settings,
      BackupCategory.profiles,
    });
  });

  test('export UI labels the four data categories', () {
    final String schemaSrc = readSyncSettingsSchemaSource();
    for (final String key in <String>[
      'backup_category_progress',
      'backup_category_statistics',
      'backup_category_settings',
      'backup_category_profiles',
    ]) {
      expect(schemaSrc.contains(key), isTrue,
          reason: '$key must be shown in the export category picker');
    }
  });

  // Source guards: the export UI must (1) gate behind a category picker that
  // (2) keeps existing categories selected but leaves videos opt-in because
  // they are usually huge, and (3) forward the chosen set to createBackup.
  test('export UI wires the category picker with video opt-in default', () {
    // TODO-585: 导出 widget 现住 sync_settings_schema/backup.part.dart；
    // 读合并语料而不是单文件。
    final String src = readSyncSettingsSchemaSource();
    expect(src.contains('_pickExportCategories('), isTrue,
        reason: 'export must prompt for categories before running');
    expect(
      src.contains('defaultBackupExportCategories()'),
      isTrue,
      reason: 'the picker must use the explicit default set',
    );
    expect(
      src.contains('!selected.contains(BackupCategory.videos)') ||
          src.contains('selected.remove(BackupCategory.videos)'),
      isTrue,
      reason: 'video files must be an explicit opt-in, not silently selected',
    );
    expect(
      src.contains('c != BackupCategory.localAudio') ||
          src.contains('!selected.contains(BackupCategory.localAudio)'),
      isTrue,
      reason: 'local audio databases must be an explicit opt-in (TODO-941)',
    );
    expect(src.contains('categories: categories'), isTrue,
        reason: 'the chosen set must be forwarded to createBackup');
  });

  // TODO-1195 part A: the export UI must offer a per-book picker and forward the
  // chosen book_keys to createBackup (dormant null = full export).
  test('export UI wires the per-book selection picker', () {
    final String src = readSyncSettingsSchemaSource();
    expect(src.contains('_pickBooks('), isTrue,
        reason: 'export must offer a per-book picker');
    expect(src.contains('_selectedBookKeys'), isTrue,
        reason: 'the picked set must be held on the widget state');
    expect(src.contains('bookKeys:'), isTrue,
        reason: 'the chosen books must be forwarded to createBackup');
  });

  test(
      'selecting localAudio packs the local_audio_*.db files (not fushi.db) '
      'and import restores them + rebases the local_audio_dbs pref', () async {
    final String dbDir = p.join(src.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    // Two local-audio DBs + a wal sidecar living flat next to fushi.db.
    await writeFile(p.join(dbDir, 'local_audio_111.db'), 'LA1');
    await writeFile(p.join(dbDir, 'local_audio_111.db-wal'), 'LA1WAL');
    await writeFile(p.join(dbDir, 'local_audio_222.db'), 'LA2');
    // An unrelated support file that must NOT be swept into the backup.
    await writeFile(p.join(dbDir, 'unrelated.db'), 'NOPE');

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.setPref(
      'local_audio_dbs',
      jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'path': p.join(dbDir, 'local_audio_111.db'),
          'displayName': 'Forvo',
          'enabled': true,
        },
        <String, Object?>{
          'path': p.join(dbDir, 'local_audio_222.db'),
          'displayName': 'NHK',
          'enabled': true,
        },
      ]),
    );

    final BackupService service = BackupService(
      db: db,
      dbDirectory: dbDir,
      appVersion: '1.0.0',
    );
    final String zip = p.join(src.path, 'la.zip');
    final BackupMeta meta = await service
        .createBackup(zip, categories: {BackupCategory.localAudio});
    await db.close();

    final Archive archive = await readZip(zip);
    expect(archive.findFile('localAudio/local_audio_111.db'), isNotNull);
    expect(archive.findFile('localAudio/local_audio_111.db-wal'), isNotNull);
    expect(archive.findFile('localAudio/local_audio_222.db'), isNotNull);
    // fushi.db is always packed, but the unrelated support file is not, and no
    // fushi.db copy leaks under the localAudio/ prefix.
    expect(archive.findFile('localAudio/unrelated.db'), isNull);
    expect(
      archive.files.any((ArchiveFile f) =>
          f.name.startsWith('localAudio/') && f.name.endsWith('fushi.db')),
      isFalse,
    );
    expect(meta.localAudioRoot, dbDir);

    // Restore into a fresh device with a DIFFERENT support dir → the pref must
    // be rebased and the files must land flat alongside the new fushi.db.
    final String dstDbDir = p.join(dst.path, 'db');
    Directory(dstDbDir).createSync(recursive: true);
    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zip,
    );

    expect(
        File(p.join(dstDbDir, 'local_audio_111.db')).readAsStringSync(), 'LA1');
    expect(
        File(p.join(dstDbDir, 'local_audio_222.db')).readAsStringSync(), 'LA2');

    final FushiDatabase restored = FushiDatabase(dstDbDir);
    try {
      final Map<String, String> prefs = await restored.getAllPrefs();
      final List<dynamic> dbs =
          jsonDecode(prefs['local_audio_dbs']!) as List<dynamic>;
      for (final dynamic e in dbs) {
        final String path = (e as Map<String, dynamic>)['path'] as String;
        expect(path, startsWith(dstDbDir),
            reason: 'pref path rebased onto this device support dir');
        expect(File(path).existsSync(), isTrue);
      }
    } finally {
      await restored.close();
    }
  });

  test(
      'importing a backup WITHOUT localAudio leaves the device local-audio DBs '
      'and pref intact (preserve-on-absent)', () async {
    // Source: books-only backup (no localAudio prefix).
    final built = await buildFullSource();
    final String zip = p.join(src.path, 'books_only.zip');
    await built.service.createBackup(zip, categories: {BackupCategory.books});
    await built.db.close();

    // Destination already has a local-audio DB + matching pref that must
    // survive the books-only restore.
    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'hoshi_books');
    Directory(dstDbDir).createSync(recursive: true);
    await writeFile(p.join(dstDbDir, 'local_audio_999.db'), 'KEEPLA');

    // Seed the device pref BEFORE the import overwrites the DB. The overwrite
    // import keeps the backup's preferences, so this exercises only the FILE
    // preservation (the file must not be deleted by the import).
    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zip,
      booksRootDirectory: dstBooks,
    );

    expect(File(p.join(dstDbDir, 'local_audio_999.db')).existsSync(), isTrue,
        reason: 'localAudio absent from backup → existing DB file untouched');
  });

  // ── TODO-1195 part C: ghost-book fix ──────────────────────────────────
  test(
      'unticking book content strips epub_books records from the DB blob '
      '(no ghost book) and zeroes the reported book count', () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'no_books.zip');
    // Everything EXCEPT books.
    final meta = await built.service.createBackup(zip, categories: {
      BackupCategory.dictionary,
      BackupCategory.audiobooks,
      BackupCategory.fonts,
    });
    await built.db.close();

    expect(meta.bookCount, 0, reason: 'no book records were exported');
    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await db.getAllEpubBooks(), isEmpty,
          reason:
              'book records must be stripped when book content is excluded');
      // The audiobook + its cues key on the same bookKey, so the cascade drops
      // them too (an audiobook without its epub row is itself un-openable).
      expect(await db.getAllAudiobooks(), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('merge-importing a books-excluded backup adds no ghost books', () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'no_books.zip');
    await built.service.createBackup(zip, categories: {BackupCategory.fonts});
    await built.db.close();

    final String dstDbDir = p.join(dst.path, 'db');
    Directory(dstDbDir).createSync(recursive: true);
    // Fresh device with no books → the backup must not add any un-openable book.
    await BackupService.mergeRestoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zip,
    );
    final FushiDatabase restored = FushiDatabase(dstDbDir);
    try {
      expect(await restored.getAllEpubBooks(), isEmpty,
          reason: 'a book-excluded backup must not resurrect books on merge');
    } finally {
      await restored.close();
    }
  });

  // ── TODO-1195 part A: per-book export ─────────────────────────────────
  test(
      'per-book export packs only the selected books (records + content); '
      'unselected books travel in neither the tree nor the DB blob', () async {
    final String dbDir = p.join(src.path, 'db');
    final String books = p.join(src.path, 'hoshi_books');
    Directory(dbDir).createSync(recursive: true);
    await writeFile(p.join(books, 'Keep', 'k.epub'), 'KEEP');
    await writeFile(p.join(books, 'Keep', 'text', 'c1.html'), 'HK');
    await writeFile(p.join(books, 'Drop', 'd.epub'), 'DROP');

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Keep',
      title: 'Keep',
      epubPath: p.join(books, 'Keep', 'k.epub'),
      extractDir: p.join(books, 'Keep'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Drop',
      title: 'Drop',
      epubPath: p.join(books, 'Drop', 'd.epub'),
      extractDir: p.join(books, 'Drop'),
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));

    final BackupService service = BackupService(
      db: db,
      dbDirectory: dbDir,
      appVersion: '1.0.0',
      booksRootDirectory: books,
    );
    final String zip = p.join(src.path, 'onebook.zip');
    final BackupMeta meta = await service.createBackup(
      zip,
      categories: {BackupCategory.books},
      bookKeys: {'Keep'},
    );
    await db.close();

    expect(meta.bookCount, 1, reason: 'only the selected book is counted');
    final Archive archive = await readZip(zip);
    // Selected book's content packed (subtree + epub).
    expect(archive.findFile('hoshi_books/Keep/k.epub'), isNotNull);
    expect(archive.findFile('hoshi_books/Keep/text/c1.html'), isNotNull);
    // Unselected book's content is absent from the archive.
    expect(archive.findFile('hoshi_books/Drop/d.epub'), isNull);
    // And its record is stripped from the DB blob (no ghost).
    final FushiDatabase restored = await openBackupDb(zip, dst);
    try {
      final Set<String> keys =
          (await restored.getAllEpubBooks()).map((b) => b.bookKey).toSet();
      expect(keys, <String>{'Keep'});
    } finally {
      await restored.close();
    }
  });

  test('per-book export: selecting every book equals a full export', () async {
    final built = await buildFullSource();
    final String zip = p.join(src.path, 'allbooks.zip');
    // buildFullSource has exactly one book 'Bk'.
    final BackupMeta meta = await built.service.createBackup(
      zip,
      categories: {BackupCategory.books},
      bookKeys: {'Bk'},
    );
    await built.db.close();

    expect(meta.bookCount, 1);
    final Archive archive = await readZip(zip);
    expect(archive.findFile('hoshi_books/Bk/original.epub'), isNotNull);
    final FushiDatabase restored = await openBackupDb(zip, dst);
    try {
      final Set<String> keys =
          (await restored.getAllEpubBooks()).map((b) => b.bookKey).toSet();
      expect(keys, <String>{'Bk'});
    } finally {
      await restored.close();
    }
  });

  // ── TODO-1193: DB-only data categories (progress/statistics/settings/
  //    profiles) selectable to EXCLUDE ────────────────────────────────
  test(
      'unticking progress strips reader_positions/bookmarks/audiobook_pos_ '
      '(statistics + settings kept)', () async {
    final built = await buildDataSource();
    final zip = p.join(src.path, 'no_progress.zip');
    await built.service
        .createBackup(zip, categories: allExcept(BackupCategory.progress));
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'reader_positions'), 0);
      expect(await countRows(db, 'bookmarks'), 0);
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.keys.any((String k) => k.startsWith('audiobook_pos_')),
          isFalse);
      expect(await countRows(db, 'reading_statistics'), 1);
      expect(prefs['theme_mode'], 'dark');
    } finally {
      await db.close();
    }
  });

  test('unticking statistics strips the statistics tables (progress kept)',
      () async {
    final built = await buildDataSource();
    final zip = p.join(src.path, 'no_stats.zip');
    await built.service
        .createBackup(zip, categories: allExcept(BackupCategory.statistics));
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'reading_statistics'), 0);
      expect(await countRows(db, 'reader_positions'), 1);
    } finally {
      await db.close();
    }
  });

  test(
      'unticking settings strips pure settings prefs but keeps audiobook '
      'positions / favorite_sentences / local_audio_dbs', () async {
    final built = await buildDataSource();
    final zip = p.join(src.path, 'no_settings.zip');
    await built.service
        .createBackup(zip, categories: allExcept(BackupCategory.settings));
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('theme_mode'), isFalse,
          reason: 'pure setting stripped');
      expect(prefs['audiobook_pos_Bk'], '12345',
          reason: 'progress pref preserved under a settings strip');
      expect(prefs.containsKey('favorite_sentences'), isTrue,
          reason: 'favorites content preserved');
      expect(prefs.containsKey('local_audio_dbs'), isTrue,
          reason: 'local-audio registry preserved');
    } finally {
      await db.close();
    }
  });

  test('unticking profiles strips the four profile-layer tables', () async {
    final built = await buildDataSource();
    final zip = p.join(src.path, 'no_profiles.zip');
    await built.service
        .createBackup(zip, categories: allExcept(BackupCategory.profiles));
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'profiles'), 0);
      expect(await countRows(db, 'profile_settings'), 0);
      expect(await countRows(db, 'media_type_profiles'), 0);
      expect(await countRows(db, 'book_profiles'), 0);
    } finally {
      await db.close();
    }
  });

  // Import-safety invariant (RED LINE): excluding settings/profiles on export
  // must NEVER wipe the importing device's local settings/profiles to empty.
  test(
      'overwrite import (importSettings=true) of a settings+profiles-excluded '
      'backup preserves the LOCAL settings + profiles (never wiped empty)',
      () async {
    final built = await buildDataSource();
    final zip = p.join(src.path, 'no_set_prof.zip');
    await built.service.createBackup(zip,
        categories: BackupCategory.values.toSet()
          ..remove(BackupCategory.settings)
          ..remove(BackupCategory.profiles));
    await built.db.close();

    final String dstDbDir = p.join(dst.path, 'db');
    Directory(dstDbDir).createSync(recursive: true);
    final FushiDatabase local = FushiDatabase(dstDbDir);
    await local.setPref('theme_mode', 'local_dark');
    await local.insertProfile(ProfilesCompanion.insert(
        name: 'LocalProfile', createdAt: 9, updatedAt: 9));
    await local.close();

    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zip,
    );

    final FushiDatabase restored = FushiDatabase(dstDbDir);
    try {
      expect((await restored.getAllEpubBooks()).map((b) => b.bookKey).toSet(),
          contains('Bk'));
      final Map<String, String> prefs = await restored.getAllPrefs();
      expect(prefs['theme_mode'], 'local_dark',
          reason:
              'local setting preserved, not wiped by an empty backup layer');
      expect((await restored.getAllProfiles()).map((r) => r.name).toSet(),
          contains('LocalProfile'),
          reason: 'local profile preserved');
    } finally {
      await restored.close();
    }
  });

  test(
      'overwrite import (importSettings=true) of an all-in backup applies the '
      'backup settings (preserve does NOT trigger)', () async {
    final built = await buildDataSource();
    final zip = p.join(src.path, 'full.zip');
    await built.service.createBackup(zip);
    await built.db.close();

    final String dstDbDir = p.join(dst.path, 'db');
    Directory(dstDbDir).createSync(recursive: true);
    final FushiDatabase local = FushiDatabase(dstDbDir);
    await local.setPref('theme_mode', 'local_dark');
    await local.close();

    await BackupService.restoreBackup(dbDirectory: dstDbDir, zipPath: zip);

    final FushiDatabase restored = FushiDatabase(dstDbDir);
    try {
      final Map<String, String> prefs = await restored.getAllPrefs();
      expect(prefs['theme_mode'], 'dark',
          reason: 'all-in backup: settings come from backup, not preserved');
    } finally {
      await restored.close();
    }
  });

  // ── BUG-828: orphan user-data tables gated by content, never leaked ──────
  //
  // Seeds a collection membership, a shelf entry and a tag on the source's
  // 'Bk' book (buildDataSource already inserts epub 'Bk'), plus search history
  // and every deletion tombstone. The three "always-wipe" tables must vanish
  // regardless of categories; collections/shelf/tags must FOLLOW the book.
  Future<void> seedOrphanRows(FushiDatabase db) async {
    final int cid = await db.createMediaCollection('C1');
    await db.addToCollection(cid, MediaKind.epub, 'Bk');
    await db.upsertShelfOrder(MediaKind.epub, 'Bk', 0);
    final int tid = await db.createTag('T1', 0xFF112233);
    await db.addTagToBook('Bk', tid);
    await db.upsertSearchHistoryItem(SearchHistoryItemsCompanion.insert(
        historyKey: 'dict', searchTerm: '猫', uniqueKey: 'dict:猫'));
    await db.insertBookTombstone('OldBook');
    await db.insertStatisticsTombstone('OldBook', 'book');
    await db.upsertCollectionMemberTombstone(
        collectionName: 'Gone',
        collectionType: 'collection',
        mediaType: 'epub',
        entryKey: 'X',
        deletedAt: 1);
  }

  test(
      'search history is ALWAYS stripped, but a full export KEEPS deletion '
      'tombstones (they carry to the cross-device merge)', () async {
    final built = await buildDataSource();
    await seedOrphanRows(built.db);
    final zip = p.join(src.path, 'all_in_orphans.zip');
    await built.service.createBackup(zip); // null = every category
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'search_history_items'), 0);
      expect(await countRows(db, 'book_tombstones'), 1,
          reason: 'books ticked → tombstone travels');
      expect(await countRows(db, 'statistics_tombstones'), 1,
          reason: 'statistics ticked → tombstone travels');
      expect(await countRows(db, 'collection_member_tombstones'), 1,
          reason: 'book/video content travels → member tombstone travels');
    } finally {
      await db.close();
    }
  });

  test(
      'deletion tombstones are stripped when their content category is excluded',
      () async {
    final built = await buildDataSource();
    await seedOrphanRows(built.db);
    final zip = p.join(src.path, 'no_content_orphans.zip');
    // Every content category unticked (the "dictionary + audio only" shape).
    await built.service.createBackup(zip, categories: <BackupCategory>{});
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'search_history_items'), 0);
      expect(await countRows(db, 'book_tombstones'), 0);
      expect(await countRows(db, 'statistics_tombstones'), 0);
      expect(await countRows(db, 'collection_member_tombstones'), 0);
    } finally {
      await db.close();
    }
  });

  test(
      'dangling srt member/shelf (no srt_books row) is stripped in a '
      'content-excluding export but kept in a full export (merge-union)',
      () async {
    // Full export: the srt member survives (cross-device union).
    final full = await buildDataSource();
    final int fcid = await full.db.createMediaCollection('SrtCol');
    await full.db.addToCollection(fcid, MediaKind.srt, 'ghost_srt');
    await full.db.upsertShelfOrder(MediaKind.srt, 'ghost_srt', 0);
    final fzip = p.join(src.path, 'srt_full.zip');
    await full.service.createBackup(fzip);
    await full.db.close();
    final FushiDatabase fdb = await openBackupDb(fzip, dst);
    try {
      expect(await countRows(fdb, 'media_collection_items'), 1,
          reason: 'full export keeps the dangling srt member for merge-union');
      expect(await countRows(fdb, 'shelf_entries'), 1);
    } finally {
      await fdb.close();
    }

    // Content-excluding export: the dangling srt row is dropped.
    final none = await buildDataSource();
    final int ncid = await none.db.createMediaCollection('SrtCol');
    await none.db.addToCollection(ncid, MediaKind.srt, 'ghost_srt');
    await none.db.upsertShelfOrder(MediaKind.srt, 'ghost_srt', 0);
    final nzip = p.join(src.path, 'srt_none.zip');
    await none.service.createBackup(nzip, categories: <BackupCategory>{});
    await none.db.close();
    final FushiDatabase ndb = await openBackupDb(nzip, dst);
    try {
      expect(await countRows(ndb, 'media_collection_items'), 0,
          reason: 'dangling srt member dropped (no srt_books to resolve)');
      expect(await countRows(ndb, 'shelf_entries'), 0);
      expect(await countRows(ndb, 'media_collections'), 0,
          reason: 'collection emptied by the srt strip is dropped');
    } finally {
      await ndb.close();
    }
  });

  test(
      'a full export keeps a member-less, tag-only collection (never treated as '
      'strip-emptied)', () async {
    final built = await buildDataSource();
    final int cid = await built.db.createMediaCollection('TagOnly');
    final int tid = await built.db.createTag('Genre', 0xFF445566);
    await built.db.addTagToCollection(cid, tid);
    final zip = p.join(src.path, 'tagonly.zip');
    await built.service.createBackup(zip);
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'media_collections'), 1,
          reason: 'always-empty tag carrier is preserved, not strip-dropped');
    } finally {
      await db.close();
    }
  });

  // ── BUG-832: dictionary_history (private) + media_sources (local paths) ──
  Future<void> seedHistoryAndSources(FushiDatabase db) async {
    await db.replaceAllDictionaryHistory(<DictionaryHistoryCompanion>[
      DictionaryHistoryCompanion.insert(
          position: 0, resultJson: '{"searchTerm":"猫"}'),
    ]);
    await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books', mediaKind: 'book', rootPath: 'D:/books', createdAt: 1));
    await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Videos',
        mediaKind: 'video',
        rootPath: 'D:/videos',
        createdAt: 1));
  }

  test(
      'dictionary_history is always wiped; media_sources are kept in a full '
      'export (BUG-832)', () async {
    final built = await buildDataSource();
    await seedHistoryAndSources(built.db);
    final zip = p.join(src.path, 'bug832_full.zip');
    await built.service.createBackup(zip);
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'dictionary_history'), 0,
          reason: 'recent lookups are a private trace, never travel');
      expect(await countRows(db, 'media_sources'), 2,
          reason: 'full export keeps both library roots for restore');
    } finally {
      await db.close();
    }
  });

  test(
      'media_sources follow the content category: book/video roots dropped when '
      'their category is excluded (BUG-832)', () async {
    final built = await buildDataSource();
    await seedHistoryAndSources(built.db);
    final zip = p.join(src.path, 'bug832_none.zip');
    await built.service.createBackup(zip, categories: <BackupCategory>{});
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'dictionary_history'), 0);
      expect(await countRows(db, 'media_sources'), 0,
          reason: 'both book & video source roots (local paths) dropped');
    } finally {
      await db.close();
    }
  });

  test(
      'excluding only videos drops the video source root but keeps the book one '
      '(BUG-832)', () async {
    final built = await buildDataSource();
    await seedHistoryAndSources(built.db);
    final zip = p.join(src.path, 'bug832_novideo.zip');
    await built.service
        .createBackup(zip, categories: allExcept(BackupCategory.videos));
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      final rows =
          await db.customSelect('SELECT media_kind FROM media_sources').get();
      final kinds = rows.map((r) => r.data['media_kind'] as String).toList();
      expect(kinds, <String>['book'],
          reason: 'only the video root is dropped; the book root stays');
    } finally {
      await db.close();
    }
  });

  test(
      'collections / shelf / tags FOLLOW their book: kept when the book is '
      'exported', () async {
    final built = await buildDataSource();
    await seedOrphanRows(built.db);
    final zip = p.join(src.path, 'orphans_kept.zip');
    await built.service.createBackup(zip); // book 'Bk' travels
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'media_collections'), 1);
      expect(await countRows(db, 'media_collection_items'), 1);
      expect(await countRows(db, 'shelf_entries'), 1);
      expect(await countRows(db, 'book_tags'), 1);
      expect(await countRows(db, 'book_tag_mappings'), 1);
    } finally {
      await db.close();
    }
  });

  test(
      'collections / shelf / tags are stripped when their book is NOT exported '
      '(unticking books empties the collection + drains the tag pool)',
      () async {
    final built = await buildDataSource();
    await seedOrphanRows(built.db);
    final zip = p.join(src.path, 'orphans_stripped.zip');
    // Book excluded → 'Bk' is stripped → its membership/shelf/tag mapping go,
    // the now-empty collection is dropped, and the orphaned tag pool row too.
    await built.service
        .createBackup(zip, categories: allExcept(BackupCategory.books));
    await built.db.close();

    final FushiDatabase db = await openBackupDb(zip, dst);
    try {
      expect(await countRows(db, 'epub_books'), 0, reason: 'book stripped');
      expect(await countRows(db, 'media_collection_items'), 0);
      expect(await countRows(db, 'media_collections'), 0,
          reason: 'empty collection dropped');
      expect(await countRows(db, 'shelf_entries'), 0);
      expect(await countRows(db, 'book_tag_mappings'), 0,
          reason: 'FK cascade cleared the mapping with the book');
      expect(await countRows(db, 'book_tags'), 0,
          reason: 'tag pool drained of the now-unreferenced tag');
    } finally {
      await db.close();
    }
  });
}
