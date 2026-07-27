import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  late MediaTrackingRepository repository;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repository = MediaTrackingRepository(db);
  });

  tearDown(() => db.close());

  test('EPUB TOC progress counts logical chapters instead of spine files', () {
    final int progress = estimateCompletedBookChapters(
      chaptersJson: '''
[
  {"href":"text/nav.xhtml"},
  {"href":"text/chapter-1.xhtml"},
  {"href":"text/illustration.xhtml"},
  {"href":"text/chapter-2.xhtml"}
]
''',
      tocJson: '''
[
  {"title":"目次","href":"text/nav.xhtml"},
  {"title":"第一話","href":"text/chapter-1.xhtml"},
  {"title":"第二話","href":"text/chapter-2.xhtml"}
]
''',
      sectionIndex: 2,
      sectionCompleted: false,
      bookCompleted: false,
      fallbackProgress: 17,
    );

    expect(progress, 1);
  });

  test('completed EPUB reports all logical TOC chapters', () {
    final int progress = estimateCompletedBookChapters(
      chaptersJson: '[{"href":"text/a.xhtml"},{"href":"text/b.xhtml"}]',
      tocJson:
          '[{"title":"序章","href":"text/a.xhtml"},{"title":"終章","href":"text/b.xhtml"}]',
      sectionIndex: 1,
      sectionCompleted: true,
      bookCompleted: true,
      fallbackProgress: 2,
    );

    expect(progress, 2);
  });

  test('mapping upsert keeps the stable local identity unique', () async {
    final int first = await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book-a',
      mediaTitle: 'A',
      kind: TrackingKind.novel,
      subjectId: 1,
      subjectName: 'Remote A',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 1,
    );
    final int second = await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book-a',
      mediaTitle: 'A revised',
      kind: TrackingKind.manga,
      subjectId: 2,
      subjectName: 'Remote B',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );

    expect(second, first);
    expect(await repository.listMappings(), hasLength(1));
    final MediaTrackingMappingRow row =
        (await repository.listMappings()).single;
    expect(row.subjectId, 2);
    expect(row.kind, 'manga');
  });

  test('automatic mapping never overwrites an existing manual choice',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'manual-book',
      mediaTitle: 'Manual',
      kind: TrackingKind.novel,
      subjectId: 10,
      subjectName: 'Chosen manually',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );

    final MediaTrackingMappingRow row = await repository.saveMappingIfAbsent(
      mediaType: TrackingMediaType.book,
      mediaKey: 'manual-book',
      mediaTitle: 'Automatic',
      kind: TrackingKind.manga,
      subjectId: 99,
      subjectName: 'Guessed automatically',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 3,
    );

    expect(row.subjectId, 10);
    expect(row.subjectName, 'Chosen manually');
    expect(row.progressMode, TrackingProgressMode.chapter.value);
  });

  test('outbox merges with max progress and completed OR', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '9',
      mediaTitle: 'Anime',
      kind: TrackingKind.anime,
      subjectId: 99,
      subjectName: 'Anime remote',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );

    await repository.enqueueProgress(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '9',
      localProgress: 4,
      completed: false,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '9',
      localProgress: 2,
      completed: true,
    );

    final PendingTrackingUpdate update = (await repository.dueUpdates()).single;
    expect(update.outbox.progress, 5);
    expect(update.outbox.completed, isTrue);
    expect(await repository.pendingCount(), 1);
  });

  test('successful delete is optimistic and does not remove a newer event',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      mediaTitle: 'Book',
      kind: TrackingKind.novel,
      subjectId: 10,
      subjectName: 'Remote',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      localProgress: 2,
      completed: false,
    );
    final MediaTrackingOutboxRow stale =
        (await repository.dueUpdates()).single.outbox;
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      localProgress: 3,
      completed: false,
    );

    await repository.markSucceeded(stale);

    expect(await repository.pendingCount(), 1);
    expect((await repository.dueUpdates()).single.outbox.progress, 3);
  });

  group('游戏收藏状态', () {
    Future<void> insertGame(
      String id, {
      required String name,
      int playStatus = 0,
      int addedAt = 1000,
    }) =>
        db.upsertGalgame(
          GalgamesCompanion.insert(
            id: id,
            name: name,
            exePath: 'C:\\games\\$id.exe',
            workdir: 'C:\\games',
            addedAt: addedAt,
            playStatus: Value<int>(playStatus),
          ),
        );

    Future<void> insertSource(
      String gameId, {
      required String source,
      required String? externalId,
    }) =>
        db.upsertGalgameSource(
          GalgameSourcesCompanion.insert(
            gameId: gameId,
            source: source,
            externalId: Value<String?>(externalId),
            dataJson: '{}',
            fetchedAt: 1000,
          ),
        );

    Future<int> gameMappingId(String gameId) => repository.saveMapping(
          mediaType: TrackingMediaType.game,
          mediaKey: gameId,
          mediaTitle: 'Game',
          kind: TrackingKind.game,
          subjectId: 77,
          subjectName: 'Remote game',
          progressMode: TrackingProgressMode.status,
          progressOffset: 0,
        );

    test('状态回退不被单调合并吃掉（弃坑 → 在玩）', () async {
      await gameMappingId('g1');
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.game,
        mediaKey: 'g1',
        localProgress: 5,
        completed: false,
        monotonic: false,
      );
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.game,
        mediaKey: 'g1',
        localProgress: 3,
        completed: false,
        monotonic: false,
      );

      expect(await repository.pendingCount(), 1);
      expect((await repository.dueUpdates()).single.outbox.progress, 3);
    });

    test('completed 在非单调模式下同样如实覆盖（玩过 → 在玩）', () async {
      await gameMappingId('g1');
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.game,
        mediaKey: 'g1',
        localProgress: 2,
        completed: true,
        monotonic: false,
      );
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.game,
        mediaKey: 'g1',
        localProgress: 3,
        completed: false,
        monotonic: false,
      );

      final MediaTrackingOutboxRow outbox =
          (await repository.dueUpdates()).single.outbox;
      expect(outbox.progress, 3);
      expect(outbox.completed, isFalse);
    });

    test('单调模式仍然只增不减（不破坏观看/阅读进度语义）', () async {
      await repository.saveMapping(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        mediaTitle: 'Video',
        kind: TrackingKind.anime,
        subjectId: 9,
        subjectName: 'Remote',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 0,
      );
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        localProgress: 8,
        completed: true,
      );
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        localProgress: 3,
        completed: false,
      );

      final MediaTrackingOutboxRow outbox =
          (await repository.dueUpdates()).single.outbox;
      expect(outbox.progress, 8);
      expect(outbox.completed, isTrue);
    });

    test('只认 bgm 源的 externalId，VNDB 的 v 前缀 id 不当 subject id 用', () async {
      await insertGame('g1', name: 'Sakura');
      await insertSource('g1', source: 'vndb', externalId: 'v12345');

      expect((await repository.loadAutoGameSource('g1'))?.bangumiSubjectId,
          isNull);

      await insertSource('g1', source: 'bgm', externalId: '4242');
      final AutoGameTrackingSource? source =
          await repository.loadAutoGameSource('g1');
      expect(source?.name, 'Sakura');
      expect(source?.bangumiSubjectId, 4242);
    });

    test('未设置状态(0)的游戏不参与对账，不会凭空建远端收藏', () async {
      await insertGame('g0', name: 'Untouched');
      await insertGame('g1', name: 'Playing', playStatus: 3);
      await insertSource('g1', source: 'bgm', externalId: '4242');

      final List<PersistedGameTrackingStatus> statuses =
          await repository.loadPersistedGameTrackingStatus(afterMs: 0);

      expect(statuses.map((s) => s.gameId), <String>['g1']);
      expect(statuses.single.status, 3);
      expect(statuses.single.bangumiSubjectId, 4242);
    });

    test('对账水位过滤掉已经对齐过的游戏', () async {
      await insertGame('g1', name: 'Playing', playStatus: 3, addedAt: 5000);

      expect(
        await repository.loadPersistedGameTrackingStatus(afterMs: 5000),
        isEmpty,
      );
      expect(
        await repository.loadPersistedGameTrackingStatus(afterMs: 4999),
        hasLength(1),
      );
    });

    test('新建映射会让老游戏重新进入对账（映射 updatedAt 抬高 evidence）', () async {
      await insertGame('g1', name: 'Playing', playStatus: 3, addedAt: 1000);
      await gameMappingId('g1');

      // 映射刚建，updatedAt 是当下，远高于 addedAt=1000。
      expect(
        await repository.loadPersistedGameTrackingStatus(afterMs: 2000),
        hasLength(1),
      );
    });
  });
}
