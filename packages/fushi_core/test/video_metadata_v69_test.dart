import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

FushiDatabase _freshDatabase() => FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase raw) {
          raw.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );

Future<int> _insertVideoSource(FushiDatabase db) => db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Videos',
        mediaKind: 'video',
        rootPath: r'D:\Videos',
        createdAt: 1,
      ),
    );

Future<void> _insertVideo(
  FushiDatabase db,
  String bookUid, {
  int? sourceId,
}) =>
    db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: 'D:/Videos/$bookUid.mkv',
        sourceId: Value<int?>(sourceId),
      ),
    );

void main() {
  group('schema v69 video metadata', () {
    late FushiDatabase db;

    setUp(() {
      db = _freshDatabase();
    });

    tearDown(() => db.close());

    test('work owner constraint and stable season/episode replacement',
        () async {
      final int sourceId = await _insertVideoSource(db);
      final int collectionId =
          await db.createMediaCollection('Series', collectionType: 'playlist');
      await _insertVideo(db, 'movie', sourceId: sourceId);
      await _insertVideo(db, 'episode-01', sourceId: sourceId);

      final int tvWorkId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(collectionId),
          mediaType: 'tv',
          title: 'Series',
          updatedAt: 10,
        ),
      );
      final int movieWorkId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('movie'),
          mediaType: 'movie',
          title: 'Movie',
          updatedAt: 10,
        ),
      );
      expect((await db.getVideoMetadataWorkByCollection(collectionId))!.id,
          tvWorkId);
      expect((await db.getVideoMetadataWorkByBook('movie'))!.id, movieWorkId);
      final int sameTvWorkId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(collectionId),
          mediaType: 'tv',
          title: 'Series renamed by provider',
          updatedAt: 11,
        ),
      );
      expect(sameTvWorkId, tvWorkId);
      expect(
        (await db.getVideoMetadataWorkByCollection(collectionId))!.title,
        'Series renamed by provider',
      );

      await expectLater(
        db.into(db.videoMetadataWorks).insert(
              VideoMetadataWorksCompanion.insert(
                mediaType: 'movie',
                title: 'No owner',
                updatedAt: 10,
              ),
            ),
        throwsA(anything),
      );
      await expectLater(
        db.into(db.videoMetadataWorks).insert(
              VideoMetadataWorksCompanion.insert(
                collectionId: Value<int?>(collectionId),
                bookUid: const Value<String?>('movie'),
                mediaType: 'movie',
                title: 'Two owners',
                updatedAt: 10,
              ),
            ),
        throwsA(anything),
      );

      await db.replaceVideoMetadataSeasons(
        tvWorkId,
        <VideoMetadataSeasonsCompanion>[
          VideoMetadataSeasonsCompanion.insert(
            workId: tvWorkId,
            seasonNumber: 1,
            title: const Value<String?>('Season 1'),
            updatedAt: 10,
          ),
        ],
      );
      final int seasonId =
          (await db.getVideoMetadataSeasons(tvWorkId)).single.id;
      await db.replaceVideoMetadataSeasons(
        tvWorkId,
        <VideoMetadataSeasonsCompanion>[
          VideoMetadataSeasonsCompanion.insert(
            workId: -1,
            seasonNumber: 1,
            title: const Value<String?>('Season One'),
            updatedAt: 11,
          ),
          VideoMetadataSeasonsCompanion.insert(
            workId: -1,
            seasonNumber: 2,
            updatedAt: 11,
          ),
        ],
      );
      final List<VideoMetadataSeasonRow> seasons =
          await db.getVideoMetadataSeasons(tvWorkId);
      expect(seasons.map((VideoMetadataSeasonRow row) => row.seasonNumber),
          <int>[1, 2]);
      expect(seasons.first.id, seasonId,
          reason: 'same season keeps its row id');

      await db.replaceVideoMetadataEpisodes(
        seasonId,
        <VideoMetadataEpisodesCompanion>[
          VideoMetadataEpisodesCompanion.insert(
            seasonId: seasonId,
            bookUid: const Value<String?>('episode-01'),
            episodeNumber: 1,
            title: const Value<String?>('Episode 1'),
            updatedAt: 12,
          ),
        ],
      );
      final int episodeId =
          (await db.getVideoMetadataEpisodes(seasonId)).single.id;
      await db.replaceVideoMetadataEpisodes(
        seasonId,
        <VideoMetadataEpisodesCompanion>[
          VideoMetadataEpisodesCompanion.insert(
            seasonId: -1,
            bookUid: const Value<String?>('episode-01'),
            episodeNumber: 1,
            title: const Value<String?>('Episode One'),
            updatedAt: 13,
          ),
        ],
      );
      expect((await db.getVideoMetadataEpisodes(seasonId)).single.id, episodeId,
          reason: 'same episode keeps its row id');

      await db.deleteVideoBook('episode-01');
      expect(
          (await db.getVideoMetadataEpisodes(seasonId)).single.bookUid, isNull,
          reason: 'deleting a local file only unbinds the provider episode');
    });

    test('provider graph, terms, people, credits and images replace by owner',
        () async {
      final int collectionId = await db.createMediaCollection('Anime');
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(collectionId),
          mediaType: 'tv',
          title: 'Anime',
          updatedAt: 20,
        ),
      );

      await db.replaceVideoMetadataProviderIdentities(
        workId: workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:tmdb',
            provider: 'tmdb',
            externalId: '100',
            isPrimary: const Value<bool>(true),
            updatedAt: 20,
          ),
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:imdb',
            provider: 'imdb',
            externalId: 'tt100',
            updatedAt: 20,
          ),
        ],
      );
      await db.replaceVideoMetadataRawSnapshots(
        'work:$workId:tmdb',
        <VideoMetadataRawSnapshotsCompanion>[
          VideoMetadataRawSnapshotsCompanion.insert(
            identityKey: 'ignored-by-dao',
            snapshotKind: 'details',
            rawJson: '{"id":100}',
            fetchedAt: 20,
          ),
        ],
      );
      expect(await db.getVideoMetadataProviderIdentities(workId: workId),
          hasLength(2));
      expect(
        (await db.getVideoMetadataRawSnapshots('work:$workId:tmdb'))
            .single
            .rawJson,
        '{"id":100}',
      );

      await db.replaceVideoMetadataTermsForWork(
        workId: workId,
        terms: <VideoMetadataTermsCompanion>[
          VideoMetadataTermsCompanion.insert(
            termKey: 'genre:animation',
            kind: 'genre',
            name: 'Animation',
            normalizedName: 'animation',
          ),
        ],
        mappings: <VideoMetadataWorkTermsCompanion>[
          VideoMetadataWorkTermsCompanion.insert(
            workId: -1,
            termKey: 'genre:animation',
          ),
        ],
      );
      expect((await db.getVideoMetadataTermsForWork(workId)).single.name,
          'Animation');

      await db.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
        VideoMetadataPeopleCompanion.insert(
          personKey: 'tmdb:person:7',
          name: 'Voice Actor',
          updatedAt: 20,
        ),
      ]);
      await db.upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
        VideoMetadataCharactersCompanion.insert(
          characterKey: 'bangumi:character:8',
          name: 'Hero',
          updatedAt: 20,
        ),
      ]);
      await db.replaceVideoMetadataCredits(
        workId: workId,
        credits: <VideoMetadataCreditsCompanion>[
          VideoMetadataCreditsCompanion.insert(
            personKey: 'tmdb:person:7',
            characterKey: const Value<String?>('bangumi:character:8'),
            creditKind: 'voice_actor',
            roleName: const Value<String>('Hero'),
            language: const Value<String?>('ja'),
          ),
        ],
      );
      final VideoMetadataCreditRow credit =
          (await db.getVideoMetadataCredits(workId: workId)).single;
      expect(credit.creditKind, 'voice_actor');
      expect(credit.characterKey, 'bangumi:character:8');
      expect(
        (await db.getVideoMetadataPerson('tmdb:person:7'))?.name,
        'Voice Actor',
      );
      expect(
        (await db.getVideoMetadataCharacter('bangumi:character:8'))?.name,
        'Hero',
      );

      await db.replaceVideoMetadataImages(
        workId: workId,
        images: <VideoMetadataImagesCompanion>[
          VideoMetadataImagesCompanion.insert(
            provider: 'fanart',
            kind: 'backdrop',
            remoteUrl: 'https://images.example/backdrop.jpg',
            updatedAt: 20,
          ),
        ],
      );
      expect((await db.getVideoMetadataImages(workId: workId)).single.provider,
          'fanart');
    });

    test('source settings, run and artifact survive/remove with intended FKs',
        () async {
      final int sourceId = await _insertVideoSource(db);
      await _insertVideo(db, 'movie', sourceId: sourceId);
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('movie'),
          mediaType: 'movie',
          title: 'Movie',
          updatedAt: 30,
        ),
      );

      await db.upsertVideoSourceScrapeSettings(
        VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          providerOverride: const Value<String?>('bangumi'),
          autoAfterScan: const Value<bool>(true),
          updatedAt: 30,
        ),
      );
      final VideoSourceScrapeSettingRow settings =
          (await db.getVideoSourceScrapeSettings(sourceId))!;
      expect(settings.enabled, isTrue);
      expect(settings.providerOverride, 'bangumi');
      expect(settings.nfoPolicy, 'missingOnly');

      final int runId = await db.insertVideoSourceScrapeRun(
        VideoSourceScrapeRunsCompanion.insert(
          sourceId: Value<int?>(sourceId),
          scope: 'source',
          status: 'running',
          startedAt: 30,
          updatedAt: 30,
        ),
      );
      await db.updateVideoSourceScrapeRun(
        runId,
        const VideoSourceScrapeRunsCompanion(
          status: Value<String>('completed'),
          processedWorks: Value<int>(1),
          succeededWorks: Value<int>(1),
          updatedAt: Value<int>(31),
          finishedAt: Value<int?>(31),
        ),
      );
      expect((await db.getVideoSourceScrapeRun(runId))!.status, 'completed');

      const String path = r'D:\Videos\Movie.nfo';
      final int artifactId = await db.upsertVideoSidecarArtifact(
        VideoSidecarArtifactsCompanion.insert(
          sourceId: Value<int?>(sourceId),
          runId: Value<int?>(runId),
          workId: Value<int?>(workId),
          artifactKind: 'nfo',
          path: path,
          sha256: 'old',
          generatorVersion: '1',
          writePolicy: 'missingOnly',
          createdAt: 30,
          updatedAt: 30,
        ),
      );
      final int sameArtifactId = await db.upsertVideoSidecarArtifact(
        VideoSidecarArtifactsCompanion.insert(
          sourceId: Value<int?>(sourceId),
          runId: Value<int?>(runId),
          workId: Value<int?>(workId),
          artifactKind: 'nfo',
          path: path,
          sha256: 'new',
          generatorVersion: '1',
          writePolicy: 'overwrite',
          createdAt: 30,
          updatedAt: 31,
        ),
      );
      expect(sameArtifactId, artifactId);
      expect((await db.getVideoSidecarArtifactByPath(path))!.sha256, 'new');
      expect(
          await db.getVideoSidecarArtifacts(sourceId: sourceId), hasLength(1));

      await db.deleteMediaSource(sourceId);
      expect(await db.getVideoSourceScrapeSettings(sourceId), isNull,
          reason: 'source-owned settings cascade with the source');
      expect((await db.getVideoSourceScrapeRun(runId))!.sourceId, isNull,
          reason: 'run audit remains after source removal');
      final VideoSidecarArtifactRow artifact =
          (await db.getVideoSidecarArtifactByPath(path))!;
      expect(artifact.sourceId, isNull);
      expect(artifact.sha256, 'new',
          reason: 'sidecar ownership/hash record must remain');
      expect((await db.getVideoBookByBookUid('movie'))!.sourceId, isNull,
          reason: 'existing media remains in the library');
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    });
  });

  test('opening the database interrupts a scrape left running by a hard exit',
      () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'fushi-video-scrape-recovery-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final String databasePath =
        '${temp.path}${Platform.pathSeparator}fushi.db';

    final FushiDatabase first = FushiDatabase.atFile(databasePath);
    final int sourceId = await _insertVideoSource(first);
    final int runId = await first.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'running',
        startedAt: 100,
        updatedAt: 100,
      ),
    );
    await first.close();

    final FushiDatabase secondary = FushiDatabase.atFile(
      databasePath,
      isMainProcess: false,
    );
    expect((await secondary.getVideoSourceScrapeRun(runId))!.status, 'running',
        reason: 'a popup/secondary process must not interrupt the main task');
    await secondary.close();

    final FushiDatabase reopened = FushiDatabase.atFile(databasePath);
    addTearDown(reopened.close);
    final VideoSourceScrapeRunRow recovered =
        (await reopened.getVideoSourceScrapeRun(runId))!;

    expect(recovered.status, 'interrupted');
    expect(recovered.phase, 'interrupted');
    expect(recovered.finishedAt, isNotNull);
    expect(recovered.updatedAt, recovered.finishedAt);
  });

  test('v68 -> v69 creates all metadata tables without touching old rows',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase raw) {
          raw.execute('PRAGMA foreign_keys = OFF');
          raw.execute('''
CREATE TABLE media_sources (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL,
  media_kind TEXT NOT NULL,
  transport TEXT NOT NULL DEFAULT 'local',
  root_path TEXT NOT NULL,
  config_json TEXT,
  media_count INTEGER NOT NULL DEFAULT 0,
  last_scanned_at INTEGER,
  last_scan_error TEXT,
  recursive INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)''');
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
          raw.execute(
            "INSERT INTO media_sources "
            "(id, label, media_kind, root_path, created_at) "
            "VALUES (4, 'Existing source', 'video', 'D:/Videos', 1)",
          );
          raw.execute(
            "INSERT INTO media_collections (id, name, created_at) "
            "VALUES (9, 'Existing collection', 1)",
          );
          raw.execute('PRAGMA user_version = 68');
          raw.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    addTearDown(db.close);

    final int version =
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');
    expect(version, db.schemaVersion);
    expect(db.schemaVersion, greaterThanOrEqualTo(69));

    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: const Value<int?>(9),
        mediaType: 'tv',
        title: 'Existing collection',
        updatedAt: 40,
      ),
    );
    expect(workId, greaterThan(0));
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: const Value<int>(4),
        updatedAt: 40,
      ),
    );
    expect(await db.getVideoSourceScrapeSettings(4), isNotNull);

    final List<Map<String, Object?>> rows = await db
        .customSelect('SELECT name FROM media_collections WHERE id = 9')
        .get()
        .then((List<QueryRow> result) => <Map<String, Object?>>[
              for (final QueryRow row in result) row.data,
            ]);
    expect(rows.single['name'], 'Existing collection');
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test('v70 keeps local extras while online extras are reconciled', () async {
    final FushiDatabase db = _freshDatabase();
    addTearDown(db.close);
    await _insertVideo(db, 'movie');
    await _insertVideo(db, 'local-trailer');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('movie'),
        mediaType: 'movie',
        title: 'Movie',
        updatedAt: 70,
      ),
    );
    await db.upsertVideoMetadataExtra(
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'local:local-trailer',
        workId: workId,
        bookUid: const Value<String?>('local-trailer'),
        kind: 'trailer',
        sourceKind: 'local',
        title: 'Local trailer',
        updatedAt: 70,
      ),
    );
    await db.replaceOnlineVideoMetadataExtras(
        workId, <VideoMetadataExtrasCompanion>[
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'tmdb:abc',
        workId: workId,
        kind: 'trailer',
        sourceKind: 'online',
        title: 'Official trailer',
        provider: const Value<String?>('tmdb'),
        providerVideoId: const Value<String?>('abc'),
        remoteUrl: const Value<String?>('https://youtu.be/abc'),
        updatedAt: 70,
      ),
    ]);
    await db.replaceOnlineVideoMetadataExtras(
        workId, <VideoMetadataExtrasCompanion>[
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'tmdb:def',
        workId: workId,
        kind: 'featurette',
        sourceKind: 'online',
        title: 'Featurette',
        remoteUrl: const Value<String?>('https://youtu.be/def'),
        updatedAt: 71,
      ),
    ]);

    final List<VideoMetadataExtraRow> extras =
        await db.getVideoMetadataExtras(workId);
    expect(extras.map((VideoMetadataExtraRow row) => row.extraKey),
        containsAll(<String>['local:local-trailer', 'tmdb:def']));
    expect(extras.map((VideoMetadataExtraRow row) => row.extraKey),
        isNot(contains('tmdb:abc')));
    expect(
      db.schemaVersion,
      greaterThanOrEqualTo(69),
      reason: 'v69 = video metadata extras used by this test',
    );
  });
}
