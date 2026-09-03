import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

const List<String> _scrapeTables = <String>[
  'collection_relations',
  'collection_scrape_meta',
  'video_scrape_meta',
  'media_images',
  'video_metadata_works',
  'video_metadata_seasons',
  'video_metadata_episodes',
  'video_metadata_provider_identities',
  'video_metadata_raw_snapshots',
  'video_metadata_terms',
  'video_metadata_work_terms',
  'video_metadata_people',
  'video_metadata_characters',
  'video_metadata_credits',
  'video_metadata_images',
  'video_metadata_extras',
  'video_source_scrape_runs',
  'video_sidecar_artifacts',
];

FushiDatabase _freshDatabase() => FushiDatabase.forTesting(
  NativeDatabase.memory(
    setup: (CommonDatabase raw) {
      raw.execute('PRAGMA foreign_keys = ON');
    },
  ),
);

Future<int> _rowCount(FushiDatabase db, String table) async {
  final QueryRow row = await db
      .customSelect('SELECT COUNT(*) AS value FROM $table')
      .getSingle();
  return row.read<int>('value');
}

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
  String? coverPath,
}) => db.upsertVideoBook(
  VideoBooksCompanion.insert(
    bookUid: bookUid,
    title: bookUid,
    videoPath: 'D:/Videos/$bookUid.mkv',
    sourceId: Value<int?>(sourceId),
    coverPath: Value<String?>(coverPath),
  ),
);

Future<int> _insertCollectionWork(
  FushiDatabase db,
  int collectionId,
  String title,
) => db.upsertVideoMetadataWork(
  VideoMetadataWorksCompanion.insert(
    collectionId: Value<int?>(collectionId),
    mediaType: 'tv',
    title: title,
    updatedAt: 1,
  ),
);

Future<int> _insertBookWork(FushiDatabase db, String bookUid, String title) =>
    db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: Value<String?>(bookUid),
        mediaType: 'movie',
        title: title,
        updatedAt: 1,
      ),
    );

Future<void> _replaceWorkIdentities(
  FushiDatabase db,
  int workId,
  List<({String provider, bool primary})> identities,
) => db.replaceVideoMetadataProviderIdentities(
  workId: workId,
  identities: <VideoMetadataProviderIdentitiesCompanion>[
    for (final ({String provider, bool primary}) identity in identities)
      VideoMetadataProviderIdentitiesCompanion.insert(
        identityKey: 'work:$workId:${identity.provider}',
        provider: identity.provider,
        externalId: '$workId-${identity.provider}',
        isPrimary: Value<bool>(identity.primary),
        updatedAt: 1,
      ),
  ],
);

void main() {
  group('video scrape record cleanup', () {
    late FushiDatabase db;

    setUp(() {
      db = _freshDatabase();
    });

    tearDown(() => db.close());

    test('aniDbScrapedVideoCollectionIds only returns collections with a '
        'primary AniDB work identity', () async {
      final int aniDbCollection = await db.createMediaCollection(
        'AniDB series',
      );
      final int localCollection = await db.createMediaCollection(
        'Local provisional',
      );
      final int tmdbCollection = await db.createMediaCollection(
        'TMDB-only series',
      );
      final int secondaryAniDbCollection = await db.createMediaCollection(
        'TMDB primary series',
      );

      final int aniDbWork = await _insertCollectionWork(
        db,
        aniDbCollection,
        'AniDB series',
      );
      await _replaceWorkIdentities(
        db,
        aniDbWork,
        <({String provider, bool primary})>[
          (provider: 'anidb', primary: true),
          (provider: 'tmdb', primary: false),
        ],
      );

      await _insertCollectionWork(db, localCollection, 'Local provisional');
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(localCollection),
          source: 'local',
          subjectId: 'local:$localCollection',
          title: 'Local provisional',
          scrapedAt: DateTime.utc(2026),
        ),
      );

      final int tmdbWork = await _insertCollectionWork(
        db,
        tmdbCollection,
        'TMDB-only series',
      );
      await _replaceWorkIdentities(
        db,
        tmdbWork,
        <({String provider, bool primary})>[(provider: 'tmdb', primary: true)],
      );

      final int secondaryAniDbWork = await _insertCollectionWork(
        db,
        secondaryAniDbCollection,
        'TMDB primary series',
      );
      await _replaceWorkIdentities(
        db,
        secondaryAniDbWork,
        <({String provider, bool primary})>[
          (provider: 'tmdb', primary: true),
          (provider: 'anidb', primary: false),
        ],
      );

      await _insertVideo(db, 'standalone-anidb');
      final int standaloneWork = await _insertBookWork(
        db,
        'standalone-anidb',
        'Standalone AniDB movie',
      );
      await _replaceWorkIdentities(
        db,
        standaloneWork,
        <({String provider, bool primary})>[(provider: 'anidb', primary: true)],
      );

      expect(
        await db.aniDbScrapedVideoCollectionIds(),
        <int>{aniDbCollection},
        reason:
            'work existence, local projections, TMDB primary identities, '
            'and secondary AniDB cross-references are not completed AniDB '
            'series scrapes',
      );
      expect(await db.aniDbScrapedVideoBookUids(), <String>{
        'standalone-anidb',
      });
    });

    test('presentation watcher includes cleanup run marker changes', () async {
      final Future<void> changed = expectLater(
        db.watchVideoScrapePresentationChanged(),
        emits(isNull),
      );

      await db.insertVideoSourceScrapeRun(
        VideoSourceScrapeRunsCompanion.insert(
          scope: 'cleanup',
          status: 'clearing',
          startedAt: 1,
          updatedAt: 1,
        ),
      );

      await changed;
    });

    test('sidecar ledger cleanup batches beyond SQLite variable limits', () async {
      final Set<int> artifactIds = <int>{};
      await db.transaction(() async {
        for (int index = 0; index < 1005; index++) {
          artifactIds.add(
            await db.upsertVideoSidecarArtifact(
              VideoSidecarArtifactsCompanion.insert(
                artifactKind: 'nfo',
                path: 'D:/Videos/batched-$index.nfo',
                sha256: 'hash-$index',
                generatorVersion: '1',
                writePolicy: 'missingOnly',
                createdAt: 1,
                updatedAt: 1,
              ),
            ),
          );
        }
      });

      await db.clearAllVideoScrapeRecords(
        preserveAllSidecarArtifacts: true,
      );
      expect(await db.getVideoSidecarArtifacts(), hasLength(1005));

      await db.clearAllVideoScrapeRecords(
        clearSidecarArtifactIds: artifactIds,
      );
      expect(await db.getVideoSidecarArtifacts(), isEmpty);
    });

    test('clearAllVideoScrapeRecords clears every scrape projection but keeps '
        'library structure, settings, and unselected covers', () async {
      final int sourceId = await _insertVideoSource(db);
      await _insertVideo(
        db,
        'clear-cover',
        sourceId: sourceId,
        coverPath: r'D:\generated\episode.jpg',
      );
      await _insertVideo(
        db,
        'keep-cover',
        sourceId: sourceId,
        coverPath: r'D:\manual\episode.jpg',
      );

      final int clearCoverCollection = await db.createMediaCollection(
        'Generated cover series',
      );
      final int keepCoverCollection = await db.createMediaCollection(
        'Manual cover series',
      );
      await db.updateMediaCollectionCoverPath(
        clearCoverCollection,
        r'D:\generated\series.jpg',
      );
      await db.updateMediaCollectionCoverPath(
        keepCoverCollection,
        r'D:\manual\series.jpg',
      );
      await db.addToCollection(
        clearCoverCollection,
        MediaKind.video,
        'clear-cover',
      );
      await db.addToCollection(
        keepCoverCollection,
        MediaKind.video,
        'keep-cover',
      );

      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: 'clear-cover',
          source: 'anidb',
          subjectId: '101',
          title: 'Generated cover series - 01',
          scrapedAt: DateTime.utc(2026),
        ),
      );
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(clearCoverCollection),
          source: 'anidb',
          subjectId: '101',
          title: 'Generated cover series',
          backdropPath: const Value<String?>(
            r'D:\generated\legacy-migrated-backdrop.jpg',
          ),
          scrapedAt: DateTime.utc(2026),
        ),
      );
      await db.replaceCollectionRelations(
        clearCoverCollection,
        <CollectionRelationsCompanion>[
          CollectionRelationsCompanion.insert(
            collectionId: clearCoverCollection,
            relationType: 'sequel',
            targetCollectionId: Value<int?>(keepCoverCollection),
            source: 'anidb',
            subjectId: '102',
            title: 'Manual cover series',
          ),
          CollectionRelationsCompanion.insert(
            collectionId: clearCoverCollection,
            relationType: 'sequel',
            targetCollectionId: Value<int?>(keepCoverCollection),
            source: 'local',
            subjectId: 'collection:$keepCoverCollection',
            title: '用户按季拆分关系',
            sortIndex: const Value<int>(1),
          ),
        ],
      );
      await db.replaceMediaImagesForCollection(
        clearCoverCollection,
        <MediaImagesCompanion>[
          MediaImagesCompanion.insert(
            collectionId: Value<int?>(clearCoverCollection),
            kind: MediaImageKind.backdrop.dbValue,
            path: r'D:\generated\backdrop.jpg',
            sourceUrl: const Value<String?>(
              'https://images.example/backdrop.jpg',
            ),
          ),
          // v68 从 collection_scrape_meta.backdrop_path 搬来的行没有
          // sourceUrl；仍须随其精确对应的刮削 meta 一起清掉。
          MediaImagesCompanion.insert(
            collectionId: Value<int?>(clearCoverCollection),
            kind: MediaImageKind.backdrop.dbValue,
            position: const Value<int>(1),
            path: r'D:\generated\legacy-migrated-backdrop.jpg',
          ),
        ],
      );
      await db.replaceMediaImagesForBook('clear-cover', <MediaImagesCompanion>[
          MediaImagesCompanion.insert(
            bookUid: const Value<String?>('clear-cover'),
            kind: MediaImageKind.logo.dbValue,
            path: r'D:\generated\logo.png',
            sourceUrl: const Value<String?>(
              'https://images.example/logo.png',
            ),
          ),
        ]);
      await db.replaceMediaImagesForCollection(
        keepCoverCollection,
        <MediaImagesCompanion>[
          MediaImagesCompanion.insert(
            collectionId: Value<int?>(keepCoverCollection),
            kind: MediaImageKind.backdrop.dbValue,
            path: r'D:\manual\backdrop.jpg',
          ),
        ],
      );

      final int workId = await _insertCollectionWork(
        db,
        clearCoverCollection,
        'Generated cover series',
      );
      await _replaceWorkIdentities(
        db,
        workId,
        <({String provider, bool primary})>[(provider: 'anidb', primary: true)],
      );
      await db.replaceVideoMetadataRawSnapshots(
        'work:$workId:anidb',
        <VideoMetadataRawSnapshotsCompanion>[
          VideoMetadataRawSnapshotsCompanion.insert(
            identityKey: 'replaced-by-dao',
            snapshotKind: 'details',
            rawJson: '{"aid":101}',
            fetchedAt: 1,
          ),
        ],
      );
      await db
          .replaceVideoMetadataSeasons(workId, <VideoMetadataSeasonsCompanion>[
            VideoMetadataSeasonsCompanion.insert(
              workId: workId,
              seasonNumber: 1,
              title: const Value<String?>('Season 1'),
              updatedAt: 1,
            ),
          ]);
      final int seasonId = (await db.getVideoMetadataSeasons(workId)).single.id;
      await db.replaceVideoMetadataEpisodes(
        seasonId,
        <VideoMetadataEpisodesCompanion>[
          VideoMetadataEpisodesCompanion.insert(
            seasonId: seasonId,
            bookUid: const Value<String?>('clear-cover'),
            episodeNumber: 1,
            title: const Value<String?>('Episode 1'),
            updatedAt: 1,
          ),
        ],
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
            workId: workId,
            termKey: 'genre:animation',
          ),
        ],
      );
      await db.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
        VideoMetadataPeopleCompanion.insert(
          personKey: 'anidb:person:7',
          name: 'Voice Actor',
          updatedAt: 1,
        ),
      ]);
      await db.upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
        VideoMetadataCharactersCompanion.insert(
          characterKey: 'anidb:character:8',
          name: 'Hero',
          updatedAt: 1,
        ),
      ]);
      await db.replaceVideoMetadataCredits(
        workId: workId,
        credits: <VideoMetadataCreditsCompanion>[
          VideoMetadataCreditsCompanion.insert(
            personKey: 'anidb:person:7',
            characterKey: const Value<String?>('anidb:character:8'),
            creditKind: 'voice_actor',
            roleName: const Value<String>('Hero'),
          ),
        ],
      );
      await db.replaceVideoMetadataImages(
        workId: workId,
        images: <VideoMetadataImagesCompanion>[
          VideoMetadataImagesCompanion.insert(
            provider: 'anidb',
            kind: 'poster',
            remoteUrl: 'https://images.example/poster.jpg',
            updatedAt: 1,
          ),
        ],
      );
      await db.upsertVideoMetadataExtra(
        VideoMetadataExtrasCompanion.insert(
          extraKey: 'anidb:trailer:1',
          workId: workId,
          kind: 'trailer',
          sourceKind: 'online',
          title: 'Trailer',
          provider: const Value<String?>('anidb'),
          remoteUrl: const Value<String?>('https://videos.example/trailer'),
          updatedAt: 1,
        ),
      );

      await db.upsertVideoSourceScrapeSettings(
        VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          providerOverride: const Value<String?>('anidb'),
          autoAfterScan: const Value<bool>(true),
          updatedAt: 1,
        ),
      );
      final int runId = await db.insertVideoSourceScrapeRun(
        VideoSourceScrapeRunsCompanion.insert(
          sourceId: Value<int?>(sourceId),
          scope: 'source',
          status: 'completed',
          startedAt: 1,
          updatedAt: 2,
          finishedAt: const Value<int?>(2),
        ),
      );
      await db.upsertVideoSidecarArtifact(
        VideoSidecarArtifactsCompanion.insert(
          sourceId: Value<int?>(sourceId),
          runId: Value<int?>(runId),
          workId: Value<int?>(workId),
          artifactKind: 'nfo',
          path: r'D:\Videos\Generated cover series\tvshow.nfo',
          sha256: 'generated-hash',
          generatorVersion: '1',
          writePolicy: 'missingOnly',
          createdAt: 1,
          updatedAt: 2,
        ),
      );
      await db.insertVideoSourceScrapeRun(
        VideoSourceScrapeRunsCompanion.insert(
          scope: 'all',
          status: 'completed',
          startedAt: 3,
          updatedAt: 4,
          finishedAt: const Value<int?>(4),
        ),
      );
      await db.upsertVideoSidecarArtifact(
        VideoSidecarArtifactsCompanion.insert(
          artifactKind: 'nfo',
          path: r'D:\Videos\orphan.nfo',
          sha256: 'orphan-hash',
          generatorVersion: '1',
          writePolicy: 'missingOnly',
          createdAt: 3,
          updatedAt: 4,
        ),
      );

      for (final String table in _scrapeTables) {
        expect(
          await _rowCount(db, table),
          greaterThan(0),
          reason: 'fixture must exercise $table before cleanup',
        );
      }
      expect(await db.aniDbScrapedVideoCollectionIds(), <int>{
        clearCoverCollection,
      });

      await db.clearAllVideoScrapeRecords(
        clearBookCoverPaths: const <String, String>{
          'clear-cover': r'D:\generated\episode.jpg',
        },
        clearCollectionCoverPaths: <int, String>{
          clearCoverCollection: r'D:\generated\series.jpg',
        },
        clearLegacyScrapedMediaImagePaths: <int, String>{
          clearCoverCollection: r'D:\generated\legacy-migrated-backdrop.jpg',
        },
      );

      Future<void> expectCleanAndRetained() async {
        for (final String table in _scrapeTables) {
          expect(
            await _rowCount(db, table),
            switch (table) {
              'collection_relations' || 'media_images' => 1,
              _ => 0,
            },
            reason: switch (table) {
              'collection_relations' => '用户建立的 local 合集关系必须跨刮削清理保留',
              'media_images' => 'sourceUrl 为空的手动附加图必须跨刮削清理保留',
              _ => '$table is reconstructible scrape state',
            },
          );
        }
        final List<CollectionRelationRow> retainedRelations =
            await db.getCollectionRelations(clearCoverCollection);
        expect(retainedRelations, hasLength(1));
        expect(retainedRelations.single.source, 'local');
        expect(
          retainedRelations.single.targetCollectionId,
          keepCoverCollection,
        );
        final List<MediaImageRow> retainedImages =
            await db.getMediaImagesForCollection(keepCoverCollection);
        expect(retainedImages, hasLength(1));
        expect(retainedImages.single.path, r'D:\manual\backdrop.jpg');
        expect(retainedImages.single.sourceUrl, isNull);
        expect(
          await db.getMediaImagesForCollection(clearCoverCollection),
          isEmpty,
          reason: 'v68 迁移的无 sourceUrl backdrop 仍是刮削投影',
        );
        expect(await db.aniDbScrapedVideoCollectionIds(), isEmpty);

        expect(
          (await db.getVideoBookByBookUid('clear-cover'))!.coverPath,
          isNull,
        );
        expect(
          (await db.getVideoBookByBookUid('keep-cover'))!.coverPath,
          r'D:\manual\episode.jpg',
        );
        expect(
          (await db.getMediaCollectionById(clearCoverCollection))!.coverPath,
          isNull,
        );
        expect(
          (await db.getMediaCollectionById(keepCoverCollection))!.coverPath,
          r'D:\manual\series.jpg',
        );
        expect(await db.allVideoBooks(), hasLength(2));
        expect(await db.getAllMediaCollections(), hasLength(2));
        expect(await db.getCollectionItems(clearCoverCollection), hasLength(1));
        expect(await db.getCollectionItems(keepCoverCollection), hasLength(1));

        final VideoSourceScrapeSettingRow? settings = await db
            .getVideoSourceScrapeSettings(sourceId);
        expect(settings, isNotNull);
        expect(settings!.providerOverride, 'anidb');
        expect(settings.autoAfterScan, isTrue);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      }

      await expectCleanAndRetained();

      await db.clearAllVideoScrapeRecords(
        clearBookCoverPaths: const <String, String>{
          'clear-cover': r'D:\generated\episode.jpg',
        },
        clearCollectionCoverPaths: <int, String>{
          clearCoverCollection: r'D:\generated\series.jpg',
        },
        clearLegacyScrapedMediaImagePaths: <int, String>{
          clearCoverCollection: r'D:\generated\legacy-migrated-backdrop.jpg',
        },
      );
      await expectCleanAndRetained();
    });

    test('running run blocks cleanup before any mutation', () async {
      final int sourceId = await _insertVideoSource(db);
      await _insertVideo(
        db,
        'busy-cover',
        sourceId: sourceId,
        coverPath: r'D:\generated\busy.jpg',
      );
      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: 'busy-cover',
          source: 'anidb',
          subjectId: 'busy',
          title: 'Busy',
          scrapedAt: DateTime.utc(2026),
        ),
      );
      await db.insertVideoSourceScrapeRun(
        VideoSourceScrapeRunsCompanion.insert(
          sourceId: Value<int?>(sourceId),
          scope: 'source',
          status: 'running',
          startedAt: 1,
          updatedAt: 1,
        ),
      );

      await expectLater(
        db.clearAllVideoScrapeRecords(
          clearBookCoverPaths: const <String, String>{
            'busy-cover': r'D:\generated\busy.jpg',
          },
        ),
        throwsA(isA<VideoScrapeRecordsBusyException>()),
      );
      expect(
        (await db.getVideoBookByBookUid('busy-cover'))!.coverPath,
        r'D:\generated\busy.jpg',
      );
      expect(await db.getAllVideoScrapeMeta(), hasLength(1));
      expect(await db.getVideoSourceScrapeRuns(), hasLength(1));
    });

    test(
      'late delete failure rolls back covers and every earlier table',
      () async {
        final int sourceId = await _insertVideoSource(db);
        await _insertVideo(
          db,
          'rollback-cover',
          sourceId: sourceId,
          coverPath: r'D:\generated\rollback.jpg',
        );
        await db.upsertVideoScrapeMeta(
          VideoScrapeMetaCompanion.insert(
            bookUid: 'rollback-cover',
            source: 'anidb',
            subjectId: 'rollback',
            title: 'Rollback',
            scrapedAt: DateTime.utc(2026),
          ),
        );
        final int collectionId = await db.createMediaCollection('Rollback');
        final int workId = await _insertCollectionWork(
          db,
          collectionId,
          'Rollback',
        );
        await db.replaceVideoMetadataTermsForWork(
          workId: workId,
          terms: <VideoMetadataTermsCompanion>[
            VideoMetadataTermsCompanion.insert(
              termKey: 'genre:rollback',
              kind: 'genre',
              name: 'Rollback',
              normalizedName: 'rollback',
            ),
          ],
          mappings: <VideoMetadataWorkTermsCompanion>[
            VideoMetadataWorkTermsCompanion.insert(
              workId: workId,
              termKey: 'genre:rollback',
            ),
          ],
        );
        await db.insertVideoSourceScrapeRun(
          VideoSourceScrapeRunsCompanion.insert(
            sourceId: Value<int?>(sourceId),
            scope: 'source',
            status: 'completed',
            startedAt: 1,
            updatedAt: 2,
            finishedAt: const Value<int?>(2),
          ),
        );
        await db.customStatement('''
        CREATE TRIGGER fail_video_term_delete
        BEFORE DELETE ON video_metadata_terms
        BEGIN
          SELECT RAISE(ABORT, 'forced rollback');
        END
      ''');

        await expectLater(
          db.clearAllVideoScrapeRecords(
            clearBookCoverPaths: const <String, String>{
              'rollback-cover': r'D:\generated\rollback.jpg',
            },
          ),
          throwsA(anything),
        );
        expect(
          (await db.getVideoBookByBookUid('rollback-cover'))!.coverPath,
          r'D:\generated\rollback.jpg',
        );
        expect(await db.getAllVideoScrapeMeta(), hasLength(1));
        expect(await db.getVideoSourceScrapeRuns(), hasLength(1));
        expect(await db.getAllVideoMetadataWorks(), hasLength(1));
        expect(await _rowCount(db, 'video_metadata_terms'), 1);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      },
    );
  });
}
