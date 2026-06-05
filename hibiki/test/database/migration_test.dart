import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 14` database that lacks the sync_baselines table,
/// forcing the real `if (from < 15) createTable(syncBaselines)` onUpgrade
/// branch in database.dart to run when HibikiDatabase opens it.
Future<HibikiDatabase> _openV14DbWithoutSyncBaselines() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // A v14 DB created before SyncBaselines existed: no sync_baselines
        // table. We only need the version marker — the from<15 branch creates
        // exactly that table, and from<14 (index backfill) does not fire.
        rawDb.execute('PRAGMA user_version = 14');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 15` database that lacks the video_books table,
/// forcing the real `if (from < 16) createTable(videoBooks)` onUpgrade branch
/// in database.dart to run when HibikiDatabase opens it.
Future<HibikiDatabase> _openV15DbWithoutVideoBooks() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // A v15 DB created before VideoBooks existed: no video_books table.
        // The from<17 branch creates the full video_books table (book_uid PK).
        // The name-PK v16 step (from<16) runs first but no-ops here because
        // this synthetic seed has no epub_books id column to re-key.
        rawDb.execute('PRAGMA user_version = 15');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 20` database that has a book_uid-keyed video_books
/// table but lacks video_book_tag_mappings, forcing the real
/// `if (from < 21) createTable(videoBookTagMappings)` onUpgrade branch to run.
Future<HibikiDatabase> _openV20DbWithoutVideoTagMappings() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Minimal but realistic v20 video_books (book_uid PK) so the FK target
        // for video_book_tag_mappings exists. Only the from<21 branch fires.
        rawDb.execute(
          'CREATE TABLE video_books ('
          'book_uid TEXT NOT NULL PRIMARY KEY, '
          'title TEXT NOT NULL, '
          'video_path TEXT NOT NULL, '
          'last_position_ms INTEGER NOT NULL DEFAULT 0, '
          'current_episode INTEGER NOT NULL DEFAULT 0, '
          'delay_ms INTEGER NOT NULL DEFAULT 0)',
        );
        rawDb.execute(
          'INSERT INTO video_books(book_uid, title, video_path) '
          "VALUES('video/seed', 'Seed', '/abs/seed.mp4')",
        );
        // book_tags is a v1 baseline table (created in onCreate, never in the
        // onUpgrade ladder), so a realistic v20 DB already has it. Seed it so
        // the shared-pool assertion (createTag) works after the v21 step.
        rawDb.execute(
          'CREATE TABLE book_tags ('
          'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL UNIQUE, '
          'color_value INTEGER NOT NULL DEFAULT 4288585374, '
          'sort_order INTEGER NOT NULL DEFAULT 0, '
          'created_at INTEGER NOT NULL)',
        );
        rawDb.execute('PRAGMA user_version = 20');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

void main() {
  group('Database schema', () {
    test('fresh database has expected schema version', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 21);
    });

    test('all expected tables exist', () async {
      final db = await _openDb();
      final tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
          .get();
      final tableNames = tables.map((r) => r.data['name'] as String).toSet();

      expect(
        tableNames,
        containsAll([
          'preferences',
          'media_items',
          'epub_books',
          'audiobooks',
          'audio_cues',
          'srt_books',
          'dictionary_metadata',
          'dictionary_history',
          'profiles',
          'profile_settings',
          'book_tags',
          'book_tag_mappings',
          'reader_positions',
          'bookmarks',
          'reading_statistics',
          'anki_mappings',
          'search_history_items',
          'sync_baselines',
          'video_books',
          'video_book_tag_mappings',
        ]),
      );
    });

    test('sync_baselines table is usable on a fresh database', () async {
      final db = await _openDb();
      // Fresh DB goes through onCreate/createAll; the table exists (no
      // exception) and reports null for an absent baseline.
      expect(await db.getSyncBaseline('x', 'progress'), isNull);
    });

    test('real v14->v15 upgrade creates a usable sync_baselines table',
        () async {
      // A pre-v15 DB has no sync_baselines table; opening it must drive the
      // from<15 onUpgrade branch (createTable(syncBaselines)) rather than
      // onCreate.
      final db = await _openV14DbWithoutSyncBaselines();

      // The upgrade ladder bumped the schema to the current version (a v14 DB
      // walks the full ladder past 15 to the latest schema).
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 21);

      // The newly-migrated table exists and querying an absent baseline does
      // not throw.
      expect(await db.getSyncBaseline('x', 'progress'), isNull);
    });

    test('real v15->v17 upgrade creates a book_uid-keyed video_books table',
        () async {
      // A pre-v16 (v15) DB has no video_books table; opening it must walk the
      // ladder past the name-PK v16 step and drive the from<17 onUpgrade branch
      // (createTable(videoBooks)) — building the full schema (book_uid PK +
      // playlist_json / current_episode / audio_track_id / delay_ms) in one
      // shot, because develop users never had a video_books table.
      final db = await _openV15DbWithoutVideoBooks();

      // The upgrade ladder bumped the schema to the current version.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 21);

      // The table carries the full v17 column set (no stepwise add-column
      // ladder remains).
      final cols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(
        colNames,
        containsAll([
          'book_uid',
          'playlist_json',
          'current_episode',
          'audio_track_id',
          'delay_ms'
        ]),
      );
      // book_uid is the primary key (pk == 1); there is no autoincrement id.
      expect(colNames, isNot(contains('id')));
      final bookUidCol = cols.firstWhere((r) => r.data['name'] == 'book_uid');
      expect(bookUidCol.data['pk'], 1);

      // The newly-migrated table is usable: upsert then read back.
      await db.upsertVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/migrated'),
        title: Value('Migrated'),
        videoPath: Value('/abs/migrated.mp4'),
      ));
      final row = await db.getVideoBookByBookUid('video/migrated');
      expect(row, isNotNull);
      expect(row!.title, 'Migrated');
      expect(row.lastPositionMs, 0);
      expect(row.delayMs, 0);
    });

    test('real v20->v21 upgrade creates a usable video_book_tag_mappings table',
        () async {
      // A v20 DB has video_books but no video_book_tag_mappings; opening it must
      // drive the from<21 onUpgrade branch (createTable(videoBookTagMappings))
      // rather than onCreate.
      final db = await _openV20DbWithoutVideoTagMappings();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 21);

      // The new mapping table exists and shares the BookTags pool: tag the
      // seeded video book and read it back.
      final tagId = await db.createTag('Migrated', 0xFF112233);
      await db.addTagToVideoBook('video/seed', tagId);
      final tags = await db.getTagsForVideoBook('video/seed');
      expect(tags, hasLength(1));
      expect(tags.single.name, 'Migrated');
    });

    test('video_book_tag_mappings references video_books and book_tags',
        () async {
      final db = await _openDb();
      final fks = await db
          .customSelect("PRAGMA foreign_key_list('video_book_tag_mappings')")
          .get();
      final tables = fks.map((r) => r.data['table'] as String).toSet();
      expect(tables, containsAll(['video_books', 'book_tags']));
    });

    test('preferences table has key and value columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('preferences')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['key', 'value']));
    });

    test('media_items has unique_key column with UNIQUE constraint', () async {
      final db = await _openDb();
      final indices =
          await db.customSelect("PRAGMA index_list('media_items')").get();
      final uniqueIndices = indices
          .where((r) => r.data['unique'] == 1)
          .map((r) => r.data['name'] as String)
          .toList();
      expect(uniqueIndices, isNotEmpty);
    });

    test('epub_books has epub_path and extract_dir columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('epub_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['epub_path', 'extract_dir']));
    });

    test('audio_cues has book_key and chapter_href columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('audio_cues')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['book_key', 'chapter_href']));
    });

    test('reading_statistics has date_key and characters_read columns',
        () async {
      final db = await _openDb();
      final cols = await db
          .customSelect("PRAGMA table_info('reading_statistics')")
          .get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['date_key', 'characters_read']));
    });

    test('book_tag_mappings references book_tags via foreign key', () async {
      final db = await _openDb();
      final fks = await db
          .customSelect("PRAGMA foreign_key_list('book_tag_mappings')")
          .get();
      final tables = fks.map((r) => r.data['table'] as String).toSet();
      expect(tables, contains('book_tags'));
    });
  });
}
