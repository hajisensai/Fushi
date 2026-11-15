import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v151: three new tracking tables: the do-not-track list
/// (`media_tracking_ignored`), the capped log of sends
/// (`media_tracking_activity`) and the media server episodes no site could be
/// linked to (`media_tracking_remote_episodes`). Purely additive: links made
/// before keep working.
void main() {
  const List<String> tables = <String>[
    'media_tracking_ignored',
    'media_tracking_activity',
    'media_tracking_remote_episodes',
  ];

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

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    <Object>[table],
  ).isNotEmpty;

  test('v150 → v151: the three tables appear, existing links stay', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'tracking151',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String table in tables) {
      raw.execute('DROP TABLE $table');
    }
    raw.execute(
      'INSERT INTO media_tracking_mappings '
      '(provider, media_type, media_key, media_title, kind, subject_id, '
      'subject_name, progress_mode, progress_offset, created_at, updated_at) '
      "VALUES ('anilist', 'video', 'uid1', 'Frieren 01', 'anime', 42, "
      "'Frieren', 'episode', 1, 1, 1)",
    );
    raw.execute('PRAGMA user_version = 150');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 152);
    final MediaTrackingMappingRow link = await migrated
        .select(migrated.mediaTrackingMappings)
        .getSingle();
    expect(link.subjectId, 42);

    await migrated
        .into(migrated.mediaTrackingIgnored)
        .insert(
          MediaTrackingIgnoredCompanion.insert(
            mediaType: 'video',
            mediaKey: 'uid1',
            createdAt: 5,
          ),
        );
    final MediaTrackingIgnoredRow ignored = await migrated
        .select(migrated.mediaTrackingIgnored)
        .getSingle();
    expect(ignored.mediaTitle, '');
    expect(ignored.kind, isNull);

    await migrated
        .into(migrated.mediaTrackingActivity)
        .insert(
          MediaTrackingActivityCompanion.insert(
            provider: 'anilist',
            mediaType: 'video',
            mediaKey: 'uid1',
            mediaTitle: 'Frieren 01',
            kind: 'anime',
            progressMode: 'episode',
            progress: 1,
            ok: true,
            createdAt: 6,
          ),
        );
    expect(
      (await migrated.select(migrated.mediaTrackingActivity).getSingle())
          .completed,
      isFalse,
    );

    await migrated
        .into(migrated.mediaTrackingRemoteEpisodes)
        .insert(
          MediaTrackingRemoteEpisodesCompanion.insert(
            mediaKey: 'jellyfin|srv|u|item3',
            groupKey: 'jellyfin|srv|u|series:s1|season:1',
            title: 'Show S1E3',
            episodeNumber: 3,
            watchedAt: 7,
          ),
        );
    final MediaTrackingRemoteEpisodeRow episode = await migrated
        .select(migrated.mediaTrackingRemoteEpisodes)
        .getSingle();
    expect(episode.isMovie, isFalse);
    expect(episode.serverName, '');
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 152);
    for (final String table in tables) {
      expect(tableExists(probe, table), isTrue, reason: table);
    }
  });

  test('v151 step is idempotent when the tables already exist', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'tracking151idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 150');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await migrated.select(migrated.mediaTrackingIgnored).get(), isEmpty);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 152);
  });
}
