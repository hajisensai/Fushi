import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// TODO-106: the export dialog lets the user pick which sidecar trees travel in
/// the backup (default all). [BackupService.exportBackup]'s [categories] param
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
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  Future<void> writeFile(String path, String content) async {
    final f = File(path);
    f.parent.createSync(recursive: true);
    await f.writeAsString(content);
  }

  /// Lays out a source "device" with all four optional trees populated, plus a
  /// db row that gives the dictionary tree real metadata (so
  /// `_hasCompleteDictionaryResources` accepts it). Returns the built service +
  /// the four roots so each test can export with a different category set.
  Future<({BackupService service, HibikiDatabase db, String dictRoot})>
      buildFullSource() async {
    final String dbDir = p.join(src.path, 'db');
    final String books = p.join(src.path, 'hoshi_books');
    final String audio = p.join(src.path, 'audiobooks');
    final String fonts = p.join(src.path, 'custom_fonts');
    final String dict = p.join(src.path, 'dictionaryResources');
    Directory(dbDir).createSync(recursive: true);

    await writeFile(p.join(books, 'Bk', 'original.epub'), 'EPUB');
    await writeFile(p.join(audio, 'h', 'a.mp3'), 'MP3');
    await writeFile(p.join(fonts, 'MyFont.ttf'), 'FONT');
    await writeFile(p.join(dict, 'JMdict', 'index.bin'), 'IDX');

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
      'BackupCategory enumerates exactly the four optional sidecar trees '
      '(db is never a category)', () {
    expect(BackupCategory.values.toSet(), <BackupCategory>{
      BackupCategory.dictionary,
      BackupCategory.books,
      BackupCategory.audiobooks,
      BackupCategory.fonts,
    });
  });

  // Source guards: the export UI must (1) gate behind a category picker that
  // (2) defaults to every category selected, and (3) forward the chosen set to
  // exportBackup. These pin the wiring so a refactor can't silently drop the
  // dialog or flip the default to "nothing selected" (TODO-106).
  test('export UI wires the category picker with all-selected default', () {
    final File ui = File('lib/src/sync/sync_settings_schema.dart');
    final String src = ui.readAsStringSync();
    expect(src.contains('_pickExportCategories()'), isTrue,
        reason: 'export must prompt for categories before running');
    expect(
      RegExp(r'BackupCategory\.values\.toSet\(\)').hasMatch(src),
      isTrue,
      reason: 'the picker must start with every category ticked (default all)',
    );
    expect(src.contains('categories: categories'), isTrue,
        reason: 'the chosen set must be forwarded to exportBackup');
  });
}
