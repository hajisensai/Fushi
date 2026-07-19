import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _openV45Seed() => HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
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
          raw.execute('PRAGMA user_version = 45');
        },
      ),
    );

HibikiDatabase _openExistingV48Seed() => HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');
          raw.execute(
            "INSERT INTO preferences (key, value) VALUES ('sentinel', 'kept')",
          );
          raw.execute('PRAGMA user_version = 48');
        },
      ),
    );

Future<Set<String>> _columnNames(
  HibikiDatabase db,
  String table,
) async {
  final List<QueryRow> rows =
      await db.customSelect('PRAGMA table_info($table)').get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

Future<Set<String>> _indexNames(HibikiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      )
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

void main() {
  test('existing schema v48 database opens without downgrade refusal',
      () async {
    final HibikiDatabase db = _openExistingV48Seed();
    addTearDown(db.close);

    expect(db.schemaVersion, 48);
    expect(await db.getPref('sentinel'), 'kept',
        reason: 'opening an existing v48 DB must preserve and expose its data');
  });

  test('v45 migration adds the v46 and v47 schema before landing on v48',
      () async {
    final HibikiDatabase db = _openV45Seed();
    addTearDown(db.close);

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 48);
    expect(await _columnNames(db, 'epub_books'), contains('completed_at'));
    expect(
      await _columnNames(db, 'revealed_images'),
      containsAll(<String>['book_key', 'image_key', 'revealed_at']),
    );
  });

  test('fresh v48 database contains all v48 hot-path indexes', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.getPref('force-open');
    expect(await _columnNames(db, 'epub_books'), contains('completed_at'));
    expect(
      await _columnNames(db, 'revealed_images'),
      containsAll(<String>['book_key', 'image_key', 'revealed_at']),
    );
    expect(
      await _indexNames(db),
      containsAll(<String>[
        'idx_audio_cues_book_chapter_sentence',
        'idx_book_tag_mappings_tag_id',
        'idx_srt_book_tag_mappings_tag_id',
        'idx_video_book_tag_mappings_tag_id',
        'idx_favorite_words_source_type',
      ]),
    );
  });
}
