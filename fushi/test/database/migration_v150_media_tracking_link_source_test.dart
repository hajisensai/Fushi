import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v150: `media_tracking_mappings` gains `link_source` + `confidence`, and the
/// new `media_tracking_suggestions` table holds title matches waiting for the
/// user. Links made before v150 must keep working and read as "source
/// unknown" (both columns null), never as an automatic match.
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    <Object>[table],
  ).isNotEmpty;

  test(
    'v149 → v150: existing links keep working, source reads as unknown',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'tracking150',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // Back to the v149 shape: no columns, no suggestions table, one old link.
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'ALTER TABLE media_tracking_mappings DROP COLUMN link_source',
      );
      raw.execute('ALTER TABLE media_tracking_mappings DROP COLUMN confidence');
      raw.execute('DROP TABLE media_tracking_suggestions');
      raw.execute(
        'INSERT INTO media_tracking_mappings '
        '(provider, media_type, media_key, media_title, kind, subject_id, '
        'subject_name, progress_mode, progress_offset, created_at, updated_at) '
        "VALUES ('bangumi', 'book', 'Old Book', 'Old Book', 'novel', 42, "
        "'Old Subject', 'volume', 2, 1, 1)",
      );
      raw.execute('PRAGMA user_version = 149');
      expect(
        columnsOf(raw, 'media_tracking_mappings'),
        isNot(contains('link_source')),
      );
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 152);
      final MediaTrackingMappingRow row = await migrated
          .select(migrated.mediaTrackingMappings)
          .getSingle();
      expect(row.subjectId, 42);
      expect(row.progressOffset, 2);
      expect(row.linkSource, isNull);
      expect(row.confidence, isNull);

      await migrated
          .into(migrated.mediaTrackingSuggestions)
          .insert(
            MediaTrackingSuggestionsCompanion.insert(
              provider: 'mangabaka',
              mediaType: 'book',
              mediaKey: 'Old Book',
              subjectId: 84547,
              subjectName: 'Bakemonogatari',
              subjectKind: 'novel',
              score: 0.8,
              createdAt: 2,
            ),
          );
      final MediaTrackingSuggestionRow suggestion = await migrated
          .select(migrated.mediaTrackingSuggestions)
          .getSingle();
      expect(suggestion.detailsJson, '{}');
      expect(suggestion.dismissedAt, isNull);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 152);
      expect(
        columnsOf(probe, 'media_tracking_mappings'),
        containsAll(<String>['link_source', 'confidence']),
      );
      expect(tableExists(probe, 'media_tracking_suggestions'), isTrue);
    },
  );

  test(
    'v150 step is idempotent when the columns and table already exist',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'tracking150idem',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('PRAGMA user_version = 149');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await migrated
          .into(migrated.mediaTrackingMappings)
          .insert(
            MediaTrackingMappingsCompanion.insert(
              provider: const Value<String>('mangabaka'),
              mediaType: 'book',
              mediaKey: 'New Book',
              mediaTitle: 'New Book',
              kind: 'novel',
              subjectId: 84547,
              subjectName: 'Bakemonogatari',
              progressMode: 'volume',
              createdAt: 1,
              updatedAt: 1,
              linkSource: const Value<String?>('auto'),
              confidence: const Value<double?>(0.95),
            ),
          );
      final MediaTrackingMappingRow row = await migrated
          .select(migrated.mediaTrackingMappings)
          .getSingle();
      expect(row.linkSource, 'auto');
      expect(row.confidence, 0.95);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 152);
    },
  );
}
