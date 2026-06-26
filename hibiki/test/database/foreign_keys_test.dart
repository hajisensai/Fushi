import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openRealDb() async {
  final dir = await Directory.systemTemp.createTemp('hibiki_fk_test_');
  addTearDown(() async {
    await dir.delete(recursive: true);
  });

  final db = HibikiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<int> _count(HibikiDatabase db, String table) async {
  final row =
      await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
  return row.read<int>('c');
}

Future<HibikiDatabase> _openLegacyDbWithExistingSortOrder() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = ON');
        rawDb.execute('''
CREATE TABLE epub_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  author TEXT,
  cover_path TEXT,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  toc_json TEXT,
  source_metadata TEXT,
  imported_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 4288585374,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_id INTEGER NOT NULL REFERENCES epub_books(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES book_tags(id) ON DELETE CASCADE,
  UNIQUE(book_id, tag_id)
)
''');
        rawDb.execute('PRAGMA user_version = 6');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

Future<HibikiDatabase> _openLegacyDbWithExistingReaderPositionOffset() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  ttu_char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)
''');
        rawDb.execute('PRAGMA user_version = 3');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

Future<HibikiDatabase> _openLegacyDbWithExistingDictionaryType() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('''
CREATE TABLE dictionary_metadata (
  name TEXT NOT NULL PRIMARY KEY,
  format_key TEXT NOT NULL,
  "order" INTEGER NOT NULL,
  type TEXT NOT NULL DEFAULT 'term',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  hidden_languages_json TEXT NOT NULL DEFAULT '[]',
  collapsed_languages_json TEXT NOT NULL DEFAULT '[]'
)
''');
        rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
        rawDb.execute('PRAGMA user_version = 1');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

void main() {
  test('real database connection enables sqlite foreign key enforcement',
      () async {
    final db = await _openRealDb();

    final row = await db.customSelect('PRAGMA foreign_keys').getSingle();

    expect(row.read<int>('foreign_keys'), 1);
  });

  test('deleting a profile cascades profile-owned rows', () async {
    final db = await _openRealDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    final profileId = await db.insertProfile(
      ProfilesCompanion.insert(
        name: 'Temp',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: 'pref',
        key: 'reader',
        value: 'vertical',
      ),
    );
    await db.setMediaTypeProfile('reader', profileId);
    await db.setBookProfile('reader_ttu/hoshi://book/1', profileId);

    await db.deleteProfile(profileId);

    expect(await _count(db, 'profile_settings'), 0);
    expect(await _count(db, 'media_type_profiles'), 0);
    expect(await _count(db, 'book_profiles'), 0);
  });

  test('deleting an epub book cascades tag mappings', () async {
    final db = await _openRealDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    const String bookKey = 'Book';
    await db.into(db.epubBooks).insert(
          EpubBooksCompanion.insert(
            bookKey: bookKey,
            title: 'Book',
            epubPath: '/tmp/book.epub',
            extractDir: '/tmp/book',
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: now,
          ),
        );
    final tagId = await db.into(db.bookTags).insert(
          BookTagsCompanion.insert(
            name: 'Tag',
            createdAt: now,
          ),
        );
    await db.into(db.bookTagMappings).insert(
          BookTagMappingsCompanion.insert(bookKey: bookKey, tagId: tagId),
        );

    await (db.delete(db.epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .go();

    expect(await _count(db, 'book_tag_mappings'), 0);
  });

  test(
      'deleting a media source sets source_id NULL on its books (setNull, '
      'not cascade)', () async {
    // TODO-817 M0: this is the repo's FIRST onDelete:setNull FK. _openRealDb is
    // mandatory because only the on-disk DB has PRAGMA foreign_keys=ON enforced
    // (forTesting memory DBs do not). Removing a source must KEEP the media
    // rows and null out their source_id — the opposite of cascade.
    final db = await _openRealDb();
    final now = DateTime.now().millisecondsSinceEpoch;

    final sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Drive',
        mediaKind: 'book',
        rootPath: '/srv/media',
        createdAt: now,
      ),
    );

    const String bookKey = 'SourcedBook';
    await db.into(db.epubBooks).insert(
          EpubBooksCompanion.insert(
            bookKey: bookKey,
            title: 'SourcedBook',
            epubPath: '/tmp/sb.epub',
            extractDir: '/tmp/sb',
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: now,
            sourceId: Value(sourceId),
          ),
        );
    const String bookUid = 'video/sourced';
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: 'SourcedVideo',
        videoPath: '/tmp/sv.mp4',
        sourceId: Value(sourceId),
      ),
    );

    // Precondition: both rows point at the source.
    final epubBefore = await (db.select(db.epubBooks)
          ..where((t) => t.bookKey.equals(bookKey)))
        .getSingle();
    expect(epubBefore.sourceId, sourceId);
    final videoBefore = await db.getVideoBookByBookUid(bookUid);
    expect(videoBefore!.sourceId, sourceId);

    final removed = await db.deleteMediaSource(sourceId);
    expect(removed, 1);

    // setNull: the media rows SURVIVE; only source_id is nulled.
    expect(await _count(db, 'epub_books'), 1);
    expect(await _count(db, 'video_books'), 1);
    final epubAfter = await (db.select(db.epubBooks)
          ..where((t) => t.bookKey.equals(bookKey)))
        .getSingle();
    expect(epubAfter.sourceId, isNull);
    final videoAfter = await db.getVideoBookByBookUid(bookUid);
    expect(videoAfter!.sourceId, isNull);
  });

  test('migration tolerates legacy database with existing sort order column',
      () async {
    final db = await _openLegacyDbWithExistingSortOrder();

    await db.customSelect('SELECT sort_order FROM book_tags').get();
    final row = await db.customSelect('PRAGMA user_version').getSingle();

    expect(row.read<int>('user_version'), db.schemaVersion);
  });

  test('migration tolerates legacy database with existing reader offset column',
      () async {
    final db = await _openLegacyDbWithExistingReaderPositionOffset();

    await db.customSelect('SELECT char_offset FROM reader_positions').get();
    final row = await db.customSelect('PRAGMA user_version').getSingle();

    expect(row.read<int>('user_version'), db.schemaVersion);
  });

  test(
      'migration tolerates legacy database with existing dictionary type column',
      () async {
    final db = await _openLegacyDbWithExistingDictionaryType();

    await db.customSelect('SELECT type FROM dictionary_metadata').get();
    final row = await db.customSelect('PRAGMA user_version').getSingle();

    expect(row.read<int>('user_version'), db.schemaVersion);
  });
}
