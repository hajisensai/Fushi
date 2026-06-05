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
        // The from<16 branch creates exactly that table; earlier branches
        // (from<15 etc.) do not fire at version 15.
        rawDb.execute('PRAGMA user_version = 15');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 16` database whose video_books table has the v16
/// shape (no playlist_json / current_episode columns), forcing the real
/// `if (from < 17) addColumn(...)` onUpgrade branch to add both columns.
Future<HibikiDatabase> _openV16DbWithLegacyVideoBooks() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Recreate the v16 video_books shape (before playlist_json /
        // current_episode existed). The from<17 branch must add exactly those
        // two columns via addColumn (not createTable).
        rawDb.execute('''
          CREATE TABLE video_books (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            book_uid TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            video_path TEXT NOT NULL,
            subtitle_source TEXT NULL,
            subtitle_format TEXT NULL,
            embedded_subtitle_track INTEGER NULL,
            cover_path TEXT NULL,
            last_position_ms INTEGER NOT NULL DEFAULT 0,
            imported_at INTEGER NULL
          )
        ''');
        rawDb.execute(
          "INSERT INTO video_books (book_uid, title, video_path) "
          "VALUES ('video/legacy', 'Legacy', '/abs/legacy.mp4')",
        );
        rawDb.execute('PRAGMA user_version = 16');
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
      expect(version.data['user_version'], 17);
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
      expect(version.read<int>('user_version'), 17);

      // The newly-migrated table exists and querying an absent baseline does
      // not throw.
      expect(await db.getSyncBaseline('x', 'progress'), isNull);
    });

    test('real v15->v16 upgrade creates a usable video_books table', () async {
      // A pre-v16 DB has no video_books table; opening it must drive the
      // from<16 onUpgrade branch (createTable(videoBooks)) rather than
      // onCreate.
      final db = await _openV15DbWithoutVideoBooks();

      // The upgrade ladder bumped the schema to the current version.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 17);

      // The newly-migrated table exists and is usable: upsert then read back.
      await db.upsertVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/migrated'),
        title: Value('Migrated'),
        videoPath: Value('/abs/migrated.mp4'),
      ));
      final row = await db.getVideoBookByBookUid('video/migrated');
      expect(row, isNotNull);
      expect(row!.title, 'Migrated');
      expect(row.lastPositionMs, 0);
    });

    test('real v16->v17 upgrade adds playlist_json + current_episode columns',
        () async {
      // A v16 video_books table predates the playlist columns; opening must
      // drive the from<17 branch (addColumn x2), preserving existing rows.
      final db = await _openV16DbWithLegacyVideoBooks();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 17);

      // Both new columns exist on the migrated table.
      final cols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['playlist_json', 'current_episode']));

      // The pre-existing row survives, with the default current_episode (0)
      // and null playlist_json.
      final legacy = await db.getVideoBookByBookUid('video/legacy');
      expect(legacy, isNotNull);
      expect(legacy!.currentEpisode, 0);
      expect(legacy.playlistJson, isNull);

      // The new column is writable end-to-end via the new helper.
      await db.updateVideoBookEpisode('video/legacy', 3);
      final updated = await db.getVideoBookByBookUid('video/legacy');
      expect(updated!.currentEpisode, 3);
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

    test('audio_cues has book_uid and chapter_href columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('audio_cues')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['book_uid', 'chapter_href']));
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
