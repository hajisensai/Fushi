// 下载任务确认过的身份 → 库里的哪部作品（BUG-2796）：下载管线的 scrape 阶段
// 与库内补刮 / 整源刮削共用这一个判据。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart';
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  String pathOf(String uid) => 'D:/Videos/$uid.mkv';

  Future<VideoBookRow> book(String uid) async {
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: uid,
        videoPath: pathOf(uid),
      ),
    );
    return (await db.getVideoBookByBookUid(uid))!;
  }

  Future<void> job(
    String jobId, {
    required List<String> files,
    String malId = '63337',
    VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
    int? collectionId,
    Map<String, int> sizes = const <String, int>{},
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa',
        selectedResourceId: jobId,
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('206401'),
        identityJson: Value<String?>(
          encodeVideoMediaReference(
            VideoMediaReference(
              providerId: 'anilist',
              mediaId: '206401',
              mediaKind: kind,
              discoveryCategory: VideoDiscoveryCategory.anime,
              title: 'FX戦士くるみちゃん',
              externalIds: <String, String>{'mal': malId},
            ),
          ),
        ),
        mediaKind: kind.name,
        title: 'FX戦士くるみちゃん',
        backendKind: 'embedded',
        fingerprint: 'fp',
        collectionId: Value<int?>(collectionId),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (int i = 0; i < files.length; i++) {
      await db.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: jobId,
          backendFileIndex: Value<int?>(i),
          originalRelativePath: '${files[i]}.mkv',
          currentRelativePath: '${files[i]}.mkv',
          finalAbsolutePath: Value<String?>(pathOf(files[i])),
          sizeBytes: Value<int?>(sizes[files[i]]),
          kind: const Value<String>('video'),
          status: const Value<String>(VideoDownloadJobFileStatus.imported),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  VideoSourceScrapeWork bookWork(VideoBookRow member) =>
      VideoSourceScrapeWork(source: null, title: member.title, members: <VideoBookRow>[member]);

  test('只下了第一集（单集作品）→ 作品拿到任务确认的 MAL 身份', () async {
    final VideoBookRow ep1 = await book('ep1');
    await job('j1', files: <String>['ep1']);
    final VideoSourceScrapeWork work = bookWork(ep1);

    final Map<String, VideoMetadataLookup> lookups =
        await downloadConfirmedLookupsForWorks(db, <VideoSourceScrapeWork>[work]);

    expect(lookups.keys, <String>[work.stableKey]);
    expect(lookups[work.stableKey]!.provider, VideoMetadataProviderKind.mal);
    expect(lookups[work.stableKey]!.externalId, '63337');
  });

  test('逐集下载进同一个合集：多条任务身份一致 → 合集作品拿到身份', () async {
    final int collectionId = await db.createMediaCollection('Kurumi');
    final MediaCollectionRow collection =
        (await db.getMediaCollectionById(collectionId))!;
    final VideoBookRow ep1 = await book('ep1');
    final VideoBookRow ep2 = await book('ep2');
    await job('j1', files: <String>['ep1'], collectionId: collectionId);
    await job('j2', files: <String>['ep2'], collectionId: collectionId);
    final VideoSourceScrapeWork work = VideoSourceScrapeWork(
      source: null,
      title: 'Kurumi',
      collection: collection,
      members: <VideoBookRow>[ep1, ep2],
    );

    final Map<String, VideoMetadataLookup> lookups =
        await downloadConfirmedLookupsForWorks(db, <VideoSourceScrapeWork>[work]);

    expect(lookups[work.stableKey]?.externalId, '63337');
  });

  test('两条任务给同一部作品确认了不同身份 → 不替它选', () async {
    final int collectionId = await db.createMediaCollection('Mixed');
    final MediaCollectionRow collection =
        (await db.getMediaCollectionById(collectionId))!;
    final VideoBookRow ep1 = await book('ep1');
    final VideoBookRow ep2 = await book('ep2');
    await job('j1', files: <String>['ep1'], collectionId: collectionId);
    await job(
      'j2',
      files: <String>['ep2'],
      collectionId: collectionId,
      malId: '1',
    );
    final VideoSourceScrapeWork work = VideoSourceScrapeWork(
      source: null,
      title: 'Mixed',
      collection: collection,
      members: <VideoBookRow>[ep1, ep2],
    );

    expect(
      await downloadConfirmedLookupsForWorks(db, <VideoSourceScrapeWork>[work]),
      isEmpty,
    );
  });

  test('多部电影一个种子：身份只给主片（最大文件）所在作品，并列正片不绑', () async {
    final VideoBookRow main = await book('main');
    final VideoBookRow side = await book('side');
    await job(
      'j1',
      files: <String>['main', 'side'],
      kind: VideoMetadataMediaKind.movie,
      sizes: <String, int>{'main': 4000, 'side': 1000},
    );
    final VideoSourceScrapeWork mainWork = bookWork(main);
    final VideoSourceScrapeWork sideWork = bookWork(side);

    final Map<String, VideoMetadataLookup> lookups =
        await downloadConfirmedLookupsForWorks(
      db,
      <VideoSourceScrapeWork>[mainWork, sideWork],
    );

    expect(lookups.keys, <String>[mainWork.stableKey]);
  });

  test('剧集包散在多部作品里、又不是任务的合集 → 说不清，不绑', () async {
    final VideoBookRow a = await book('a');
    final VideoBookRow b = await book('b');
    await job('j1', files: <String>['a', 'b']);

    expect(
      await downloadConfirmedLookupsForWorks(
        db,
        <VideoSourceScrapeWork>[bookWork(a), bookWork(b)],
      ),
      isEmpty,
    );
  });

  test('没有下载记录的作品 → 空', () async {
    final VideoBookRow ep1 = await book('ep1');
    expect(
      await downloadConfirmedLookupsForWorks(
        db,
        <VideoSourceScrapeWork>[bookWork(ep1)],
      ),
      isEmpty,
    );
  });
}
