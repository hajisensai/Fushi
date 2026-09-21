import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/media/video/metadata/video_tmdb_ordering_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「TMDB 集编排」（Shoko `PreferredAlternateOrderingID`）的用户面：列分组 →
/// 选一个 → 作品行写分组 id 并上 `episodeGroup` 锁 → 以既有身份（带分组 id）
/// 重刮。
class _OrderingRunner
    implements
        VideoSourceScrapeRunner,
        VideoSourceScrapeManualBinding,
        VideoSourceScrapeEpisodeOrdering {
  final List<VideoMetadataLookup> listed = <VideoMetadataLookup>[];
  final List<VideoMetadataLookup> rescraped = <VideoMetadataLookup>[];
  List<VideoMetadataEpisodeGroupSummary> groups =
      const <VideoMetadataEpisodeGroupSummary>[];

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async => SourceScrapeReport(sourceIds: <int>[source.id]);

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async => const <VideoSourceScrapeConfirmationCandidate>[];

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) =>
      Future<VideoMetadataWork?>.value(null);

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    rescraped.add(lookup);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }

  @override
  Future<List<VideoMetadataEpisodeGroupSummary>> listEpisodeGroups(
    VideoMetadataLookup lookup,
  ) async {
    listed.add(lookup);
    return groups;
  }
}

void main() {
  const SourceLibraryRow source = SourceLibraryRow(
    id: 1,
    label: 'Anime',
    mediaKind: 'video',
    transport: 'local',
    rootPath: '/videos',
    mediaCount: 0,
    recursive: true,
    videoGroupingMode: 'series',
    sortOrder: 0,
    createdAt: 1,
  );

  Future<int> seedWork(
    FushiDatabase db, {
    required String provider,
    String? episodeGroupId,
  }) async {
    final int collectionId = await db.createMediaCollection(
      'Re:Zero',
      collectionType: 'playlist',
    );
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Re:Zero',
        episodeGroupId: Value<String?>(episodeGroupId),
        updatedAt: 1,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:$provider',
          provider: provider,
          externalId: provider == 'tmdb' ? '65942' : '31240',
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
        if (provider != 'tmdb')
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:tmdb',
            provider: 'tmdb',
            externalId: '65942',
            updatedAt: 1,
          ),
      ],
    );
    return workId;
  }

  Future<bool?> open(
    WidgetTester tester,
    FushiDatabase db,
    VideoSourceScrapeTaskController controller,
    int workId,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await chooseVideoTmdbOrdering(
                  context: context,
                  database: db,
                  controller: controller,
                  source: source,
                  workTitle: 'Re:Zero',
                  workStableKey: 'collection:1',
                  workId: workId,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets(
    'picking an alternate ordering writes the group id + lock and rescrapes '
    'with the grouped lookup (TMDB primary)',
    (WidgetTester tester) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int workId = await seedWork(db, provider: 'tmdb');
      final _OrderingRunner runner = _OrderingRunner()
        ..groups = const <VideoMetadataEpisodeGroupSummary>[
          VideoMetadataEpisodeGroupSummary(
            id: 'absolute',
            name: 'Absolute',
            type: 2,
            episodeCount: 66,
          ),
          VideoMetadataEpisodeGroupSummary(
            id: 'seasons',
            name: 'Seasons',
            type: 6,
            groupCount: 3,
            episodeCount: 66,
            description: 'Split by cour',
          ),
        ];
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);

      await open(tester, db, controller, workId);
      expect(runner.listed.single.externalId, '65942');
      expect(find.text(t.collection_tmdb_ordering_default), findsOneWidget);
      expect(find.text('Seasons'), findsOneWidget);
      expect(find.textContaining('Split by cour'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('video-tmdb-ordering-seasons')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.dialog_save));
      await tester.pumpAndSettle();

      final VideoMetadataWorkRow row = (await db.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.episodeGroupId, 'seasons');
      expect(
        parseLockedFields(row.lockedFields),
        contains(VideoMetadataLockableField.episodeGroup),
      );
      expect(runner.rescraped, hasLength(1));
      expect(runner.rescraped.single.provider, VideoMetadataProviderKind.tmdb);
      expect(runner.rescraped.single.externalId, '65942');
      expect(
        runner.rescraped.single.episodeGroupId,
        'seasons',
        reason: '重刮的 lookup 带分组 id → 季集按分组编排、集级链接随之重算',
      );
    },
  );

  testWidgets(
    'choosing the default ordering back writes null and still locks',
    (WidgetTester tester) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int workId = await seedWork(
        db,
        provider: 'mal',
        episodeGroupId: 'seasons',
      );
      final _OrderingRunner runner = _OrderingRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);

      // TMDB 上已没有分组列表，但作品行还钉着一个：仍要能选回默认。
      await open(tester, db, controller, workId);
      await tester.tap(
        find.byKey(const ValueKey<String>('video-tmdb-ordering-default')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.dialog_save));
      await tester.pumpAndSettle();

      final VideoMetadataWorkRow row = (await db.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.episodeGroupId, isNull);
      expect(
        parseLockedFields(row.lockedFields),
        contains(VideoMetadataLockableField.episodeGroup),
      );
      expect(
        runner.rescraped.single.provider,
        VideoMetadataProviderKind.mal,
        reason: 'MAL 主源照旧以 MAL 身份重刮，TMDB 补充按作品行的分组走',
      );
    },
  );

  testWidgets('cancel changes nothing', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int workId = await seedWork(db, provider: 'tmdb');
    final _OrderingRunner runner = _OrderingRunner()
      ..groups = const <VideoMetadataEpisodeGroupSummary>[
        VideoMetadataEpisodeGroupSummary(
          id: 'absolute',
          name: 'Absolute',
          type: 2,
        ),
      ];
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    await open(tester, db, controller, workId);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    final VideoMetadataWorkRow row = (await db.getVideoMetadataWorkById(
      workId,
    ))!;
    expect(row.episodeGroupId, isNull);
    expect(row.lockedFields, isNull);
    expect(runner.rescraped, isEmpty);
  });
}
