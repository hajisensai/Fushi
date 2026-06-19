import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Column- and row-level guard for the **v24** reader-position migration
/// (BUG-162): `reader_positions` drops the legacy `ttu_char_offset` column and
/// adds `char_offset INTEGER NOT NULL DEFAULT -1`. The single ADD/DROP COLUMN
/// step lives at `database.dart` `if (from < 24)`.
///
/// `foreign_keys_test.dart:202` already SMOKE-covers the from<24 ADD path (a v3
/// DB walks the full ladder and `SELECT char_offset` succeeds). This file adds
/// the value the smoke can't: the exact post-migration column shape
/// (`table_info` has `char_offset`, lacks `ttu_char_offset`, PK unchanged),
/// per-row data preservation through the DROP COLUMN, the `-1` default on
/// pre-existing rows, and an upsert round-trip proving the new column is usable.
///
/// All version assertions use `db.schemaVersion` (never a hard-coded 24) so the
/// file does not re-break on every future schema bump.

/// Seeds a `user_version = 23` `reader_positions` that still carries the legacy
/// `ttu_char_offset` column and has NO `char_offset` (the real pre-v24 shape:
/// at v23 the table is already book_key-keyed by the v16 re-key). Opening it
/// drives ONLY the `from < 24` onUpgrade branch. [seededOffsets] maps book_key
/// to the seeded `ttu_char_offset` value (the column dropped by v24).
Future<HibikiDatabase> _openV23ReaderPositions(
  Map<String, int> seededOffsets,
) async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Pre-v24 reader_positions: book_key UNIQUE (post-v16 re-key shape),
        // ttu_char_offset present, char_offset ABSENT. Verbatim from the v16
        // generated schema in database.dart (`reader_positions_new`).
        rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  ttu_char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)
''');
        int order = 0;
        seededOffsets.forEach((String bookKey, int ttuCharOffset) {
          order += 1;
          rawDb.execute(
            'INSERT INTO reader_positions '
            '(book_key, section_index, norm_char_offset, ttu_char_offset, updated_at) '
            'VALUES (?, ?, ?, ?, ?)',
            <Object?>[bookKey, order, order * 100, ttuCharOffset, order * 1000],
          );
        });
        rawDb.execute('PRAGMA user_version = 23');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

Future<Set<String>> _columnNames(HibikiDatabase db, String table) async {
  final rows = await db.customSelect("PRAGMA table_info('$table')").get();
  return rows.map((r) => r.data['name'] as String).toSet();
}

void main() {
  group('reader_positions v23->v24 (drop ttu_char_offset, add char_offset)',
      () {
    test(
        'drops ttu_char_offset, adds char_offset, keeps PK, preserves every row',
        () async {
      final db = await _openV23ReaderPositions(<String, int>{
        // A row whose legacy ttu_char_offset was the -1 sentinel.
        'こころ': -1,
        // A row whose legacy ttu_char_offset held a precise offset (888) — it is
        // intentionally dropped; v24 resets to the -1 fallback.
        '吾輩は猫である': 888,
        // A third book to prove multi-row preservation.
        '坊っちゃん': 42,
      });

      // Ladder ran to the live schema version.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // (a) Column shape: char_offset present, ttu_char_offset gone, PK on id
      //     unchanged.
      final cols =
          await db.customSelect("PRAGMA table_info('reader_positions')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('char_offset'));
      expect(colNames, isNot(contains('ttu_char_offset')),
          reason: 'v24 must DROP the legacy ttu_char_offset column');
      final pkCols = cols
          .where((r) => (r.data['pk'] as int) > 0)
          .map((r) => r.data['name'] as String)
          .toList();
      expect(pkCols, equals(<String>['id']),
          reason: 'primary key is still the autoincrement id, unchanged');

      // (b) Every row preserved: 3 rows, all other columns byte-for-byte.
      final rows = await db
          .customSelect('SELECT book_key, section_index, norm_char_offset, '
              'updated_at, char_offset FROM reader_positions ORDER BY id')
          .get();
      expect(rows, hasLength(3), reason: 'DROP COLUMN must not drop rows');
      expect(rows[0].read<String>('book_key'), 'こころ');
      expect(rows[0].read<int>('section_index'), 1);
      expect(rows[0].read<int>('norm_char_offset'), 100);
      expect(rows[0].read<int>('updated_at'), 1000);
      expect(rows[1].read<String>('book_key'), '吾輩は猫である');
      expect(rows[1].read<int>('norm_char_offset'), 200);
      expect(rows[2].read<String>('book_key'), '坊っちゃん');
      expect(rows[2].read<int>('norm_char_offset'), 300);

      // (c) char_offset default: every pre-existing row gets the -1 sentinel
      //     (DROP COLUMN deletes the precise ttu offsets; recovery falls back to
      //     the normCharOffset score until the next page re-save — matches the
      //     database.dart `if (from < 24)` comment).
      for (final row in rows) {
        expect(row.read<int>('char_offset'), -1,
            reason: 'pre-v24 rows default to -1 (precise offset dropped)');
      }

      // (d) The new column is usable: upsert a precise char_offset and read it
      //     back through the typed API.
      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookKey: Value('こころ'),
        sectionIndex: Value(1),
        normCharOffset: Value(100),
        charOffset: Value(1234),
        updatedAt: Value(2000),
      ));
      final restored = await db.getReaderPosition('こころ');
      expect(restored, isNotNull);
      expect(restored!.charOffset, 1234,
          reason: 'char_offset round-trips after migration');
    });

    test(
        'idempotent when a v23 DB already has char_offset (guard skips the ADD)',
        () async {
      // Anomalous but defensible: a DB that already carries char_offset AND
      // ttu_char_offset. The from<24 step guards the ADD with
      // !_columnExists('reader_positions','char_offset'), so it must not error,
      // and must still DROP the stale ttu_char_offset.
      final db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) {
            rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  ttu_char_offset INTEGER NOT NULL DEFAULT -1,
  char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)
''');
            rawDb.execute(
              'INSERT INTO reader_positions '
              '(book_key, section_index, norm_char_offset, ttu_char_offset, '
              'char_offset, updated_at) '
              "VALUES ('こころ', 3, 555, 777, 999, 12345)",
            );
            rawDb.execute('PRAGMA user_version = 23');
          },
        ),
      );
      addTearDown(db.close);

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      final colNames = await _columnNames(db, 'reader_positions');
      expect(colNames, contains('char_offset'));
      expect(colNames, isNot(contains('ttu_char_offset')));

      // The pre-existing char_offset value is NOT clobbered (guard skipped ADD).
      final restored = await db.getReaderPosition('こころ');
      expect(restored, isNotNull);
      expect(restored!.charOffset, 999,
          reason: 'existing char_offset preserved (no re-ADD with default)');
      expect(restored.sectionIndex, 3);
      expect(restored.normCharOffset, 555);
    });

    test('tolerates a partial DB with no reader_positions table', () async {
      // A synthetic/partial seed missing reader_positions entirely: at v23 only
      // the from<24 step fires, and it is guarded by
      // _tableExists('reader_positions'), so it must SKIP rather than throw on a
      // missing table. (onCreate does not run for an existing-versioned DB, so
      // the table is legitimately absent afterwards — the contract under test is
      // "the guard prevents an ALTER on a non-existent table".)
      final db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) {
            rawDb.execute('PRAGMA user_version = 23');
          },
        ),
      );
      addTearDown(db.close);

      // Opening must complete the ladder without throwing.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      // The guard skipped the ALTER; reader_positions was never created.
      final exists = await db
          .customSelect(
              "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' "
              "AND name='reader_positions'")
          .getSingle();
      expect(exists.read<int>('c'), 0,
          reason: '_tableExists guard skipped the ADD/DROP on a partial DB');
    });
  });
}
