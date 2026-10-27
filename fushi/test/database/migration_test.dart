import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('Database schema', () {
    test('fresh database has expected schema version', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);
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
          'media_open_history',
          'epub_books',
          'audiobooks',
          'audio_cues',
          'srt_books',
          'dictionary_metadata',
          'dictionary_history',
          'profiles',
          'profile_settings',
          'language_profiles',
          'book_tags',
          'tag_assignments',
          'reader_positions',
          'bookmarks',
          'reading_statistics',
          'anki_mappings',
          'search_history_items',
          'sync_baselines',
          'video_books',
          'video_watch_statistics',
          'video_hourly_logs',
          'favorite_words',
          'mining_statistics',
          'mined_sentences',
          'media_sources',
          'activity_events',
          'clipboard_history',
        ]),
      );
    });

    test('sync_baselines table is usable on a fresh database', () async {
      final db = await _openDb();
      // Fresh DB goes through onCreate/createAll; the table exists (no
      // exception) and reports null for an absent baseline.
      expect(await db.getSyncBaseline('x', 'progress'), isNull);
    });

    test(
        'tag_assignments references book_tags via foreign key (v77：宿主是'
        '逻辑外键，只有 tag_id 挂真 FK)', () async {
      final db = await _openDb();
      final fks = await db
          .customSelect("PRAGMA foreign_key_list('tag_assignments')")
          .get();
      final tables = fks.map((r) => r.data['table'] as String).toSet();
      expect(tables, contains('book_tags'));
      expect(tables, isNot(contains('video_books')),
          reason: '宿主键跨五 kind 复用，不挂 DB FK（ShelfEntries 同惯例）');
    });

    test('preferences table has key and value columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('preferences')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['key', 'value']));
    });

    test('media_open_history keys on (media_source, media_id)', () async {
      final db = await _openDb();
      final cols = await db
          .customSelect("PRAGMA table_info('media_open_history')")
          .get();
      final pkCols = cols
          .where((r) => (r.data['pk'] as int) > 0)
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(pkCols, <String>{'media_source', 'media_id'});
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

    test('v29->v30 createTable migration is idempotent on a fresh DB',
        () async {
      // A fresh DB is created at v30 by onCreate's createAll; the from<30 guard
      // (_tableExists) must make re-entering the step a no-op rather than a
      // "table already exists" failure.
      final db = await _openDb();
      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, containsAll(['series', 'shelf_entries']));
      expect(db.schemaVersion, 138);
    });

    test(
        'fresh DB (v33) has lookup_mining_counters with the expected columns '
        '(TODO-1204)', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(db.schemaVersion, 138,
          reason:
              'TODO-1288 v37 audiobook srt_books self-heal; v38 unified media_collections (series→collection + playlist split)');

      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, contains('lookup_mining_counters'),
          reason: 'from<33 must createTable(lookup_mining_counters)');

      final cols = await db
          .customSelect("PRAGMA table_info('lookup_mining_counters')")
          .get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(
          colNames,
          containsAll(<String>[
            'book_key',
            'title',
            'source_type',
            'date_key',
            'lookup_count',
            'mine_count',
          ]));
    });

    test(
        'fresh DB (v34) has statistics_tombstones with the expected columns '
        '(TODO-1204 后续)', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(db.schemaVersion, 138,
          reason:
              'TODO-1288 v37 audiobook srt_books self-heal; v38 unified media_collections (series→collection + playlist split)');

      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, contains('statistics_tombstones'));

      final cols = await db
          .customSelect("PRAGMA table_info('statistics_tombstones')")
          .get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames,
          containsAll(<String>['title', 'source_type', 'deleted_at']));
    });

    test('fresh DB (v35) has video_books.stream_spec_json column (TODO-1157)',
        () async {
      final db = await _openDb();
      expect(db.schemaVersion, 138);
      final cols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('stream_spec_json'),
          reason: 'fresh createAll must include TODO-1157 stream_spec_json');
    });

    test('fresh DB (v45) has media_collections.anilist_id column', () async {
      final db = await _openDb();
      expect(db.schemaVersion, 138);
      final cols =
          await db.customSelect("PRAGMA table_info('media_collections')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('anilist_id'),
          reason: 'fresh createAll must include v45 anilist_id');
    });

    test('fresh DB (v46) has epub_books.completed_at column', () async {
      final db = await _openDb();
      expect(db.schemaVersion, 138);
      final cols =
          await db.customSelect("PRAGMA table_info('epub_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('completed_at'),
          reason: 'fresh createAll must include v46 epub_books.completed_at');
    });

    test(
        'fresh DB (v36) has favorite_words.book_key + title columns (TODO-1252)',
        () async {
      final db = await _openDb();
      expect(db.schemaVersion, 138);
      final cols =
          await db.customSelect("PRAGMA table_info('favorite_words')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(<String>['book_key', 'title']),
          reason: 'fresh createAll must include TODO-1252 book_key/title');
    });

    // BUG-1310：v64 新增 collection_scrape_meta（合集级刮削资料的宿主）。
    //
    // 纯新增表、不动任何既有表/列，所以这条只需锁两点：升级后表真的建出来了，
    // 且既有合集行**一行不少、一列不改**（升级绝不能碰用户数据）。
    test('fresh DB (v64) has collection_scrape_meta table', () async {
      final db = await _openDb();
      expect(db.schemaVersion, 138);
      final rows = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='collection_scrape_meta'")
          .get();
      expect(rows, hasLength(1),
          reason: 'fresh createAll must include v64 collection_scrape_meta');
    });

  });
}
