import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';

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
    final bookId = await db.into(db.epubBooks).insert(
          EpubBooksCompanion.insert(
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
          BookTagMappingsCompanion.insert(bookId: bookId, tagId: tagId),
        );

    await (db.delete(db.epubBooks)..where((t) => t.id.equals(bookId))).go();

    expect(await _count(db, 'book_tag_mappings'), 0);
  });

  test('migration tolerates legacy database with existing sort order column',
      () async {
    final db = await _openLegacyDbWithExistingSortOrder();

    await db.customSelect('SELECT sort_order FROM book_tags').get();
    final row = await db.customSelect('PRAGMA user_version').getSingle();

    expect(row.read<int>('user_version'), 12);
  });

  test('migration tolerates legacy database with existing reader offset column',
      () async {
    final db = await _openLegacyDbWithExistingReaderPositionOffset();

    await db.customSelect('SELECT ttu_char_offset FROM reader_positions').get();
    final row = await db.customSelect('PRAGMA user_version').getSingle();

    expect(row.read<int>('user_version'), 12);
  });

  test(
      'migration tolerates legacy database with existing dictionary type column',
      () async {
    final db = await _openLegacyDbWithExistingDictionaryType();

    await db.customSelect('SELECT type FROM dictionary_metadata').get();
    final row = await db.customSelect('PRAGMA user_version').getSingle();

    expect(row.read<int>('user_version'), 12);
  });
}
