// BUG-2755：删除 / 更换来源后视频下载仍落旧位置。
//
// 删来源时 FK 只把订阅与任务的 target_source_id 静默清空；改订阅来源时只写订阅
// 行，已派出的任务还固化着旧来源。这里钉住：删来源可在同一事务里把订阅与未整理完
// 的任务迁到新来源（或停用订阅）、默认下载来源偏好跟着改；改订阅来源带上还没进
// 整理的任务；扫描器跳过来源下的下载暂存目录。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_removal.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late int oldSource;
  late int newSource;

  Future<int> insertSource(String label) => db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: label,
          mediaKind: 'video',
          rootPath: p.join('C:', label),
          createdAt: 1,
        ),
      );

  Future<void> insertSubscription(String id, int sourceId) =>
      db.upsertVideoDownloadSubscription(
        VideoDownloadSubscriptionsCompanion.insert(
          subscriptionId: id,
          resourceProvider: 'nyaa:test',
          mediaKind: 'tv',
          title: 'Show $id',
          searchQuery: 'Show',
          backendKind: 'embedded',
          fingerprint: 'fp',
          targetSourceId: Value<int?>(sourceId),
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> insertJob(
    String jobId, {
    required int sourceId,
    required String stage,
    String lifecycle = VideoDownloadJobLifecycle.active,
  }) =>
      db.upsertVideoDownloadJob(
        VideoDownloadJobsCompanion.insert(
          jobId: jobId,
          resourceProvider: 'nyaa:test',
          selectedResourceId: 'release-$jobId',
          mediaKind: 'tv',
          title: 'Show',
          backendKind: 'embedded',
          fingerprint: 'fp',
          targetSourceId: Value<int?>(sourceId),
          lifecycle: Value<String>(lifecycle),
          stage: Value<String>(stage),
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> linkItem(String subscriptionId, String jobId) =>
      db.upsertVideoDownloadSubscriptionItem(
        VideoDownloadSubscriptionItemsCompanion.insert(
          subscriptionId: subscriptionId,
          logicalItemKey: 'item-$jobId',
          resourceProvider: 'nyaa:test',
          selectedResourceId: 'release-$jobId',
          title: 'Show - $jobId',
          jobId: Value<String?>(jobId),
          discoveredAt: 1,
          updatedAt: 1,
        ),
      );

  Future<int?> targetOfJob(String jobId) async =>
      (await db.getVideoDownloadJob(jobId))!.targetSourceId;

  setUp(() async {
    // 生产连接开 foreign_keys（FK setNull 是删来源语义的一半），测试连接照做。
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (dynamic raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    oldSource = await insertSource('old');
    newSource = await insertSource('new');
    await insertSubscription('sub-a', oldSource);
    await insertJob('queued', sourceId: oldSource, stage: 'enqueue');
    await insertJob('downloading', sourceId: oldSource, stage: 'download');
    await insertJob('organizing', sourceId: oldSource, stage: 'organize');
    await insertJob('importing', sourceId: oldSource, stage: 'import');
    await insertJob(
      'done',
      sourceId: oldSource,
      stage: 'scrape',
      lifecycle: VideoDownloadJobLifecycle.completed,
    );
  });

  tearDown(() => db.close());

  test('counts subscriptions and jobs whose files are not in the source yet',
      () async {
    final ({int subscriptions, int pendingJobs}) refs =
        await db.countVideoDownloadReferencesToSource(oldSource);
    expect(refs.subscriptions, 1);
    expect(refs.pendingJobs, 3, reason: 'enqueue / download / organize');
    final ({int subscriptions, int pendingJobs}) none =
        await db.countVideoDownloadReferencesToSource(newSource);
    expect(none.subscriptions, 0);
    expect(none.pendingJobs, 0);
  });

  test('removal migrates subscriptions, pending jobs and the default source',
      () async {
    await prefs.setVideoDownloadTargetSourceId(oldSource);

    await removeSourceLibrary(
      database: db,
      prefs: prefs,
      sourceId: oldSource,
      migrateVideoDownloadsTo: newSource,
    );

    expect(await db.getMediaSourceById(oldSource), isNull);
    final VideoDownloadSubscriptionRow subscription =
        (await db.getVideoDownloadSubscription('sub-a'))!;
    expect(subscription.targetSourceId, newSource);
    expect(subscription.enabled, isTrue);
    expect(await targetOfJob('queued'), newSource);
    expect(await targetOfJob('downloading'), newSource);
    expect(await targetOfJob('organizing'), newSource);
    // 文件已落进旧来源的任务不改绑（FK 照旧清空，审计保留）。
    expect(await targetOfJob('importing'), isNull);
    expect(await targetOfJob('done'), isNull);
    expect(prefs.videoDownloadTargetSourceId, newSource);
  });

  test('removal without a target pauses the orphaned subscriptions', () async {
    await prefs.setVideoDownloadTargetSourceId(oldSource);

    await removeSourceLibrary(
      database: db,
      prefs: prefs,
      sourceId: oldSource,
      disableVideoDownloadSubscriptions: true,
    );

    final VideoDownloadSubscriptionRow subscription =
        (await db.getVideoDownloadSubscription('sub-a'))!;
    expect(subscription.enabled, isFalse);
    expect(subscription.targetSourceId, isNull);
    expect(prefs.videoDownloadTargetSourceId, isNull);
  });

  test('removing another source leaves the default download source alone',
      () async {
    await prefs.setVideoDownloadTargetSourceId(newSource);

    await removeSourceLibrary(database: db, prefs: prefs, sourceId: oldSource);

    expect(prefs.videoDownloadTargetSourceId, newSource);
  });

  test('an invalid migration target rolls the whole removal back', () async {
    final int bookSource = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'books',
        mediaKind: 'book',
        rootPath: p.join('C:', 'books'),
        createdAt: 1,
      ),
    );

    await expectLater(
      db.deleteMediaSource(oldSource, migrateVideoDownloadsTo: bookSource),
      throwsArgumentError,
    );
    await expectLater(
      db.deleteMediaSource(oldSource, migrateVideoDownloadsTo: oldSource),
      throwsArgumentError,
    );

    expect(await db.getMediaSourceById(oldSource), isNotNull);
    expect(
      (await db.getVideoDownloadSubscription('sub-a'))!.targetSourceId,
      oldSource,
    );
  });

  test('changing a subscription source carries its not-yet-organized jobs',
      () async {
    await insertSubscription('sub-b', oldSource);
    await insertJob('other-sub-job', sourceId: oldSource, stage: 'download');
    for (final String jobId in <String>[
      'queued',
      'downloading',
      'organizing',
      'done',
    ]) {
      await linkItem('sub-a', jobId);
    }
    await linkItem('sub-b', 'other-sub-job');

    final int moved = await db.updateVideoDownloadSubscriptionRetargetingJobs(
      'sub-a',
      VideoDownloadSubscriptionsCompanion(
        targetSourceId: Value<int?>(newSource),
        updatedAt: const Value<int>(2),
      ),
      nowAt: 2,
    );

    expect(moved, 2);
    expect(
      (await db.getVideoDownloadSubscription('sub-a'))!.targetSourceId,
      newSource,
    );
    expect(await targetOfJob('queued'), newSource);
    expect(await targetOfJob('downloading'), newSource);
    expect(
      await targetOfJob('organizing'),
      oldSource,
      reason: '整理中的任务可能已把文件改名进旧来源，中途不换根',
    );
    expect(await targetOfJob('done'), oldSource);
    expect(await targetOfJob('other-sub-job'), oldSource);
  });

  test('editing a subscription without touching its source moves no job',
      () async {
    await linkItem('sub-a', 'queued');

    final int moved = await db.updateVideoDownloadSubscriptionRetargetingJobs(
      'sub-a',
      const VideoDownloadSubscriptionsCompanion(
        searchQuery: Value<String>('Show 2'),
      ),
      nowAt: 2,
    );

    expect(moved, 0);
    expect(await targetOfJob('queued'), oldSource);
  });

  test('the scanner skips the download staging directory of local sources', () {
    final String root = p.join('C:', 'Anime');
    SourceFileEntry entry(String path) => SourceFileEntry(
          name: p.basename(path),
          path: path,
          isDirectory: false,
        );
    final List<SourceFileEntry> entries = <SourceFileEntry>[
      entry(p.join(root, 'Show', 'Show - 01.mkv')),
      entry(p.join(root, '.fushi-incoming', 'fushi', 'Show - 02.mkv')),
    ];

    expect(
      excludeSourceIncomingEntries(entries, sourceRoot: root, isLocal: true)
          .map((SourceFileEntry e) => e.path),
      <String>[p.join(root, 'Show', 'Show - 01.mkv')],
    );
    expect(
      excludeSourceIncomingEntries(entries, sourceRoot: root, isLocal: false),
      hasLength(2),
    );
  });
}
