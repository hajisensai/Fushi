import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'sync_settings_schema_source_corpus.dart';

/// TODO-106/TODO-249: the export dialog lets the user pick which sidecar trees
/// travel in the backup. [BackupService.exportBackup]'s [categories] param
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
        if (d.existsSync()) await d.delete(recursive: true);
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
  Future<({BackupService service, HibikiDatabase db, String dictRoot})>
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

    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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

  test('null categories packs every tree (legacy all-in export)', () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'all.zip');
    final meta = await built.service.exportBackup(zip);
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
    expect(archive.findFile('hibiki.db'), isNotNull);
    // Meta records every packed tree's root.
    expect(meta.booksRoot, isNotNull);
    expect(meta.audiobooksRoot, isNotNull);
    expect(meta.fontsRoot, isNotNull);
  });

  test('selecting only books packs books + db, excludes the other trees',
      () async {
    final built = await buildFullSource();
    final zip = p.join(src.path, 'books_only.zip');
    final meta = await built.service.exportBackup(
      zip,
      categories: {BackupCategory.books},
    );
    await built.db.close();

    final archive = await readZip(zip);
    expect(archive.findFile('hibiki.db'), isNotNull,
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
    await built.service.exportBackup(zip, categories: <BackupCategory>{});
    await built.db.close();

    final archive = await readZip(zip);
    expect(archive.findFile('hibiki.db'), isNotNull);
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
    await built.service.exportBackup(zip, categories: {BackupCategory.videos});
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

    await BackupService.importBackupFiles(
      dbDirectory: dstDbDir,
      zipPath: zip,
      videosRootDirectory: dstVideos,
    );

    final HibikiDatabase restored = HibikiDatabase(dstDbDir);
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
    await built.service.exportBackup(zip, categories: {BackupCategory.books});
    await built.db.close();

    // Destination already has an audiobook tree that must survive a books-only
    // restore (the partial backup carries no audio prefix).
    final String dstDbDir = p.join(dst.path, 'db');
    final String dstBooks = p.join(dst.path, 'hoshi_books');
    final String dstAudio = p.join(dst.path, 'audiobooks');
    Directory(dstDbDir).createSync(recursive: true);
    await writeFile(p.join(dstAudio, 'keep', 'kept.mp3'), 'KEEP');

    await BackupService.importBackupFiles(
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
      'BackupCategory enumerates exactly the six optional sidecar trees '
      '(db is never a category)', () {
    expect(BackupCategory.values.toSet(), <BackupCategory>{
      BackupCategory.dictionary,
      BackupCategory.books,
      BackupCategory.audiobooks,
      BackupCategory.fonts,
      BackupCategory.videos,
      BackupCategory.localAudio,
    });
  });

  // Source guards: the export UI must (1) gate behind a category picker that
  // (2) keeps existing categories selected but leaves videos opt-in because
  // they are usually huge, and (3) forward the chosen set to exportBackup.
  test('export UI wires the category picker with video opt-in default', () {
    // TODO-585: 导出 widget 现住 sync_settings_schema/backup.part.dart；
    // 读合并语料而不是单文件。
    final String src = readSyncSettingsSchemaSource();
    expect(src.contains('_pickExportCategories()'), isTrue,
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
        reason: 'the chosen set must be forwarded to exportBackup');
  });

  test(
      'selecting localAudio packs the local_audio_*.db files (not hibiki.db) '
      'and import restores them + rebases the local_audio_dbs pref', () async {
    final String dbDir = p.join(src.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    // Two local-audio DBs + a wal sidecar living flat next to hibiki.db.
    await writeFile(p.join(dbDir, 'local_audio_111.db'), 'LA1');
    await writeFile(p.join(dbDir, 'local_audio_111.db-wal'), 'LA1WAL');
    await writeFile(p.join(dbDir, 'local_audio_222.db'), 'LA2');
    // An unrelated support file that must NOT be swept into the backup.
    await writeFile(p.join(dbDir, 'unrelated.db'), 'NOPE');

    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
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
        .exportBackup(zip, categories: {BackupCategory.localAudio});
    await db.close();

    final Archive archive = await readZip(zip);
    expect(archive.findFile('localAudio/local_audio_111.db'), isNotNull);
    expect(archive.findFile('localAudio/local_audio_111.db-wal'), isNotNull);
    expect(archive.findFile('localAudio/local_audio_222.db'), isNotNull);
    // hibiki.db is always packed, but the unrelated support file is not, and no
    // hibiki.db copy leaks under the localAudio/ prefix.
    expect(archive.findFile('localAudio/unrelated.db'), isNull);
    expect(
      archive.files.any((ArchiveFile f) =>
          f.name.startsWith('localAudio/') && f.name.endsWith('hibiki.db')),
      isFalse,
    );
    expect(meta.localAudioRoot, dbDir);

    // Restore into a fresh device with a DIFFERENT support dir → the pref must
    // be rebased and the files must land flat alongside the new hibiki.db.
    final String dstDbDir = p.join(dst.path, 'db');
    Directory(dstDbDir).createSync(recursive: true);
    await BackupService.importBackupFiles(
      dbDirectory: dstDbDir,
      zipPath: zip,
    );

    expect(
        File(p.join(dstDbDir, 'local_audio_111.db')).readAsStringSync(), 'LA1');
    expect(
        File(p.join(dstDbDir, 'local_audio_222.db')).readAsStringSync(), 'LA2');

    final HibikiDatabase restored = HibikiDatabase(dstDbDir);
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
    await built.service.exportBackup(zip, categories: {BackupCategory.books});
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
    await BackupService.importBackupFiles(
      dbDirectory: dstDbDir,
      zipPath: zip,
      booksRootDirectory: dstBooks,
    );

    expect(File(p.join(dstDbDir, 'local_audio_999.db')).existsSync(), isTrue,
        reason: 'localAudio absent from backup → existing DB file untouched');
  });
}
