import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/models/preferences_repository.dart';
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

  // 总闸的根因守卫：库内自动补刮会联网（AniDB 每日标题包，配了客户端身份时还会打
  // httpapi/TMDB），所以它必须挂在一个用户看得见、关得掉的**自己的**偏好上。修前
  // 它借用 video_auto_scrape——那个键的契约明写「不会发起元数据网络请求」、且早已
  // 从设置页撤下，等于给一项后台联网行为配了个不存在的开关。
  group('自动补刮总闸是独立且用户可控的偏好', () {
    test('默认开，读写往返，且与旧的 video_auto_scrape 互不影响', () async {
      final FushiDatabase prefsDb =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(prefsDb.close);
      final PreferencesRepository repo = PreferencesRepository(prefsDb);
      await repo.loadFromDb();

      expect(repo.videoLibraryAutoBackfillScrape, isTrue,
          reason: '默认开——存量用户升级后行为不变');

      await repo.setVideoLibraryAutoBackfillScrape(false);
      expect(repo.videoLibraryAutoBackfillScrape, isFalse);
      expect(repo.videoAutoScrape, isTrue,
          reason: '关掉补刮不得连带改动旧的本地封面 sweep 开关');

      await repo.setVideoAutoScrape(false);
      await repo.setVideoLibraryAutoBackfillScrape(true);
      expect(repo.videoAutoScrape, isFalse,
          reason: '两个键必须是两份独立状态，不是同一个键的两个名字');
      expect(repo.videoLibraryAutoBackfillScrape, isTrue);

      await repo.loadFromDb();
      expect(repo.videoLibraryAutoBackfillScrape, isTrue,
          reason: '跨 reload 持久化');
    });

    test('sweep 的接线读新偏好，且设置页真画了这个开关', () {
      final String homePage = File(
        'lib/src/pages/implementations/home_page.dart',
      ).readAsStringSync();
      expect(
        homePage,
        contains(
            'isEnabled: () => appModelNoUpdate.videoLibraryAutoBackfillScrape'),
        reason: 'sweep 必须挂在自己的总闸上',
      );
      expect(
        homePage,
        isNot(contains('videoAutoScrape')),
        reason: '不得回退到契约写着「不联网」且用户改不了的 video_auto_scrape',
      );

      final String videoSettings = File(
        'lib/src/settings/settings_schema_video.dart',
      ).readAsStringSync();
      expect(
        videoSettings,
        contains("id: 'video.library.scrape_auto_backfill'"),
        reason: '联网的后台行为必须在设置页有一个能关的开关',
      );
      expect(
        videoSettings,
        contains('setVideoLibraryAutoBackfillScrape'),
        reason: '开关必须真写穿到 sweep 读的那个偏好',
      );
    });
  });

  test('同一作品每进程只自动尝试一次', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');

    final VideoLibraryScrapeSweep service = sweep();
    await service.sweepOnce();
    await service.sweepOnce();
    // 查无/歧义的作品永远满足「无规范身份」判据：没有按作品的记账，它们会被
    // 每一轮 sweep 重新塞进批次，白占 AniDB 的进程级限流队列。
    expect(runner.sourceIds, hasLength(1));
    expect(runner.plannedTitles.single, <String>['Unscraped Movie']);
  });

  test('同一进程内新入库的作品会被后续 sweep 认领（BUG-2199）', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');

    final VideoLibraryScrapeSweep service = sweep();
    await service.sweepOnce();
    expect(runner.plannedTitles.single, <String>['Unscraped Movie']);

    // 下载管线的 import 落库必然晚于进页面那一轮 sweep（实测差 6 秒）。旧实现拿
    // 一个进程级 bool 当幂等键，于是这一条结构上永远刮不到，必须重启 app——正好
    // 废掉 BUG-2004 留下的「无 AniDB 身份的下载作品由自动补刮认领」承诺。
    await addVideo('movie-b', 'D:/A/Fresh Download (2023).mkv', sourceId,
        title: 'Fresh Download');
    await service.sweepOnce();

    expect(runner.sourceIds, hasLength(2));
    // 第二轮只带新作品：老作品已经自动试过，不重复打 AniDB。
    expect(runner.plannedTitles.last, <String>['Fresh Download']);
  });

  test('sweepAndListPending 回传待确认清单，总闸关时也照常回传', () async {
    final int sourceId = await addSource('D:/A');
    await addVideo('movie-a', 'D:/A/Unscraped Movie (2020).mkv', sourceId,
        title: 'Unscraped Movie');
    await addVideo('movie-b', 'D:/A/Scraped Movie (2021).mkv', sourceId,
        title: 'Scraped Movie');
    await seedIdentityForBook('movie-b');

    final List<VideoPendingScrapeWork> pending =
        await sweep(isEnabled: () => false).sweepAndListPending();

    // 「不自动刮」不等于「不告诉用户有东西待确认」：提醒条的数字来自这份清单。
    expect(runner.sourceIds, isEmpty);
    expect(
      pending.map((VideoPendingScrapeWork e) => e.work.title),
      <String>['Unscraped Movie'],
    );
  });
}
