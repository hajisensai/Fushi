import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _openMigratedFromV67() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = OFF');
        raw.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT,
  cover_path TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  order_updated_at INTEGER NOT NULL DEFAULT 0,
  anilist_id INTEGER,
  audio_track_id TEXT,
  subtitle_delay_ms INTEGER
)''');
        raw.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL
)''');
        raw.execute('''
CREATE TABLE collection_scrape_meta (
  collection_id INTEGER NOT NULL PRIMARY KEY,
  source TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  title TEXT NOT NULL,
  backdrop_path TEXT,
  scraped_at INTEGER NOT NULL
)''');
        raw.execute('''
CREATE TABLE video_scrape_meta (
  book_uid TEXT NOT NULL PRIMARY KEY,
  source TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  title TEXT NOT NULL,
  scraped_at INTEGER NOT NULL
)''');
        raw.execute('''
CREATE TABLE collection_relations (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  collection_id INTEGER NOT NULL,
  source TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO media_collections (id, name, created_at) "
          "VALUES (9, 'Migrated series', 1)",
        );
        raw.execute(
          'INSERT INTO collection_scrape_meta '
          '(collection_id, source, subject_id, title, backdrop_path, '
          'scraped_at) VALUES '
          "(9, 'tmdb', '42', 'Migrated series', "
          "'D:/generated/v68-backdrop.jpg', 1)",
        );
        raw.execute('PRAGMA user_version = 67');
      },
    ),
  );
}

void main() {
  test(
      'v68 migrated null-source backdrop is cleared by exact path without deleting manual image',
      () async {
    final FushiDatabase db = _openMigratedFromV67();
    addTearDown(db.close);

    final List<QueryRow> migrated = await db.customSelect(
      'SELECT collection_id, kind, position, path, source_url '
      'FROM media_images WHERE collection_id = 9',
    ).get();
    expect(migrated, hasLength(1));
    expect(migrated.single.read<String>('kind'), 'backdrop');
    expect(migrated.single.read<String>('path'),
        'D:/generated/v68-backdrop.jpg');
    expect(migrated.single.data['source_url'], isNull,
        reason: 'v68 migration intentionally had no source_url column value');

    await db.customStatement(
      'INSERT INTO media_images '
      '(collection_id, kind, position, path, source_url) VALUES '
      "(9, 'backdrop', 1, 'D:/manual/kept-backdrop.jpg', NULL)",
    );

    await db.clearAllVideoScrapeRecords(
      clearLegacyScrapedMediaImagePaths: const <int, String>{
        9: 'D:/generated/v68-backdrop.jpg',
      },
    );

    final List<QueryRow> retained = await db.customSelect(
      'SELECT path, source_url FROM media_images '
      'WHERE collection_id = 9 ORDER BY position',
    ).get();
    expect(retained, hasLength(1));
    expect(retained.single.read<String>('path'),
        'D:/manual/kept-backdrop.jpg');
    expect(retained.single.data['source_url'], isNull,
        reason: 'unlisted null-source images are user-owned and must survive');
    expect(
      await db.customSelect('SELECT * FROM collection_scrape_meta').get(),
      isEmpty,
    );
  });
}
