import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v152: `media_tracking_mappings` gains `sent_progress` + `sent_completed`
/// (what a send of the link last succeeded with). Links made before read -1
/// ("nothing recorded"), new links null.
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

  test(
    'v151 → v152: old links read "nothing recorded", new links null',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'tracking152',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'ALTER TABLE media_tracking_mappings DROP COLUMN sent_progress',
      );
      raw.execute(
        'ALTER TABLE media_tracking_mappings DROP COLUMN sent_completed',
      );
      raw.execute(
        'INSERT INTO media_tracking_mappings '
        '(provider, media_type, media_key, media_title, kind, subject_id, '
        'subject_name, progress_mode, progress_offset, created_at, updated_at) '
        "VALUES ('anilist', 'video', 'uid1', 'Frieren 01', 'anime', 42, "
        "'Frieren', 'episode', 1, 1, 1)",
      );
      raw.execute('PRAGMA user_version = 151');
      expect(
        columnsOf(raw, 'media_tracking_mappings'),
        isNot(contains('sent_progress')),
      );
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 152);
      final MediaTrackingMappingRow old = await migrated
          .select(migrated.mediaTrackingMappings)
          .getSingle();
      expect(old.subjectId, 42);
      expect(old.sentProgress, -1);
      expect(old.sentCompleted, isFalse);

      await migrated
          .into(migrated.mediaTrackingMappings)
          .insert(
            MediaTrackingMappingsCompanion.insert(
              mediaType: 'book',
              mediaKey: 'b1',
              mediaTitle: 'Book',
              kind: 'novel',
              subjectId: 7,
              subjectName: 'Book',
              progressMode: 'volume',
              createdAt: 2,
              updatedAt: 2,
            ),
          );
      final MediaTrackingMappingRow fresh = await (migrated.select(
        migrated.mediaTrackingMappings,
      )..where((t) => t.mediaKey.equals('b1'))).getSingle();
      expect(fresh.sentProgress, isNull);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 152);
      expect(
        columnsOf(probe, 'media_tracking_mappings'),
        containsAll(<String>['sent_progress', 'sent_completed']),
      );
    },
  );

  test('v152 step is idempotent and keeps recorded values', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'tracking152idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'INSERT INTO media_tracking_mappings '
      '(provider, media_type, media_key, media_title, kind, subject_id, '
      'subject_name, progress_mode, progress_offset, created_at, updated_at, '
      'sent_progress, sent_completed) '
      "VALUES ('anilist', 'video', 'uid1', 'Frieren 01', 'anime', 42, "
      "'Frieren', 'episode', 1, 1, 1, 5, 1)",
    );
    raw.execute('PRAGMA user_version = 151');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final MediaTrackingMappingRow link = await migrated
        .select(migrated.mediaTrackingMappings)
        .getSingle();
    expect(link.sentProgress, 5);
    expect(link.sentCompleted, isTrue);
    await migrated.close();
  });
}
