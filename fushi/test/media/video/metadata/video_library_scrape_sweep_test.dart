import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2000：库内自动补刮只认「从未刮出规范身份」这一条判据，批次 scope 记
/// 'sweep'；BUG-2001：集号标签型标题进待确认队列但不做自动尝试。
class _RecordingRunner implements VideoSourceScrapeRunner {
  final List<int> sourceIds = <int>[];
  final List<List<String>> plannedTitles = <List<String>>[];
  final List<String> runScopes = <String>[];

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async {
    sourceIds.add(source.id);
    plannedTitles.add(<String>[
      for (final VideoSourceScrapeWork work
          in plannedWorks ?? const <VideoSourceScrapeWork>[])
        work.title,
    ]);
    runScopes.add(runScope);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: plannedWorks?.length ?? 0,
      succeededWorks: plannedWorks?.length ?? 0,
    );
  }
}

void main() {
  late FushiDatabase db;
  late _RecordingRunner runner;
  late VideoSourceScrapeTaskController controller;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    runner = _RecordingRunner();
    controller = VideoSourceScrapeTaskController(runner);
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<int> addSource(String root) => db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: root,
          mediaKind: 'video',
          rootPath: root,
          createdAt: 1,
        ),
      );

  Future<void> addVideo(
    String uid,
    String path,
    int sourceId, {
    String? title,
  }) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(title ?? uid),
        videoPath: Value<String>(path),
        sourceId: Value<int?>(sourceId),
      ));

  /// 给某本书种上规范作品行 + 一条作品级 anidb 身份（= 已刮削）。
  Future<void> seedIdentityForBook(String bookUid) async {
    final int workId = await db.into(db.videoMetadataWorks).insert(
          VideoMetadataWorksCompanion.insert(
            bookUid: Value<String?>(bookUid),
            mediaType: 'movie',
            title: 'seeded',
            updatedAt: 1,
          ),
        );
    await db.into(db.videoMetadataProviderIdentities).insert(
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:anidb',
            workId: Value<int?>(workId),
            provider: 'anidb',
            externalId: '123',
            updatedAt: 1,
          ),
        );
  }

  VideoLibraryScrapeSweep sweep({bool Function()? isEnabled}) =>
      VideoLibraryScrapeSweep(
        database: db,
        controller: controller,
        isEnabled: isEnabled,
      );

  test('只补刮无规范身份的作品，批次 scope 记 sweep', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');
    await addVideo('movie-b', 'D:/A/Scraped Movie (2021).mkv', sourceId,
        title: 'Scraped Movie');
    await seedIdentityForBook('movie-b');

    await sweep().sweepOnce();

    expect(runner.sourceIds, <int>[sourceId]);
    expect(runner.plannedTitles.single, <String>['Unscraped Movie']);
    expect(runner.runScopes.single, 'sweep');
  });

  test('集号标签型标题进待确认队列但不自动补刮', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('extra-1', 'D:/A/extra1.mkv', sourceId, title: '特典 S00E01');

    final VideoLibraryScrapeSweep service = sweep();
    final List<VideoPendingScrapeWork> pending = await service.pendingWorks();
    expect(
      pending.map((VideoPendingScrapeWork e) => e.work.title),
      <String>['特典 S00E01'],
    );

    await service.sweepOnce();
    expect(runner.sourceIds, isEmpty);
  });

  test('来源刮削开关关闭时既不进队列也不补刮', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        enabled: const Value<bool>(false),
        updatedAt: 1,
      ),
    );

    final VideoLibraryScrapeSweep service = sweep();
    expect(await service.pendingWorks(), isEmpty);
    await service.sweepOnce();
    expect(runner.sourceIds, isEmpty);
  });

  test('自动刮削总闸关闭时不补刮（队列仍可见）', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');

    final VideoLibraryScrapeSweep service = sweep(isEnabled: () => false);
    expect(await service.pendingWorks(), hasLength(1));
    await service.sweepOnce();
    expect(runner.sourceIds, isEmpty);
  });

  test('每进程只跑一轮', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');

    final VideoLibraryScrapeSweep service = sweep();
    await service.sweepOnce();
    await service.sweepOnce();
    expect(runner.sourceIds, hasLength(1));
  });
}
