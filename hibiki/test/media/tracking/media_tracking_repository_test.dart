import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/media_tracking_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late HibikiDatabase db;
  late MediaTrackingRepository repository;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repository = MediaTrackingRepository(db);
  });

  tearDown(() => db.close());

  test('旧的已完成视频会列为待手动关联，建立映射后立即消失', () async {
    final DateTime completedAt = DateTime.fromMillisecondsSinceEpoch(5000);
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'old-video',
        title: '以前看过的番剧',
        videoPath: 'C:/video/old.mkv',
        completedAt: Value<DateTime?>(completedAt),
      ),
    );

    List<MediaTrackingUnlinkedItem> unlinked =
        await repository.listUnlinkedHistory();
    expect(unlinked, hasLength(1));
    expect(unlinked.single.mediaKey, 'old-video');
    expect(unlinked.single.lastActivityAt, 5000);

    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'old-video',
      mediaTitle: '以前看过的番剧',
      kind: TrackingKind.anime,
      subjectId: 42,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );

    unlinked = await repository.listUnlinkedHistory();
    expect(unlinked, isEmpty);
  });

  /// 按页翻的书（PDF / 漫画）没有「章」：`chaptersJson` 是 `'[]'`、`tocJson` 是 null，
  /// 阅读位置的 `sectionIndex` 存的是**页码**。旧实现在这里只挡了 `'manga'`，PDF 会
  /// 一路走到 estimateCompletedBookChapters 的「无 toc 即早退」分支拿到
  /// fallbackProgress —— 也就是把当前页码当成已读章数报进用户的 Bangumi 公开记录。
  ///
  /// 漫画当时只是**侥幸**没踩到：自动映射把它判成 volume 模式绕开了 chapter 分支，
  /// 手动把映射改成 chapter 模式一样会中招。所以两种格式都要挡。
  Future<void> seedBook(String key, BookFormat format) async {
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: key,
      title: key,
      epubPath: 'x',
      extractDir: 'd',
      chapterCount: 300,
      chaptersJson: '[]',
      importedAt: 0,
      format: Value(format.dbValue),
    ));
  }

  for (final BookFormat format in <BookFormat>[
    BookFormat.pdf,
    BookFormat.manga,
  ]) {
    test('${format.dbValue} 不产出章进度（页码不得当章数上报）', () async {
      await seedBook('b-${format.dbValue}', format);
      final int? progress = await repository.loadBookChapterProgress(
        bookKey: 'b-${format.dbValue}',
        fallbackProgress: 137, // 当前第 137 页
      );
      expect(progress, isNull,
          reason: '按页翻的书没有章，必须返回 null 让上层整条不发，'
              '而不是把 137 页当成 137 章报出去');
    });
  }

  /// 调用点②：`loadPersistedBookTrackingProgress` 原本**完全没有 format 守卫**。
  ///
  /// 这条单独存在，是因为变异实测证明它必须存在：把 `:564` 那行 format 守卫删掉，
  /// 只覆盖 `loadBookChapterProgress` 的测试**照样全绿**——两个调用点必须各有各的
  /// 钉子，否则「只修一处、另一处漂开」会静默复发。
  for (final BookFormat format in <BookFormat>[
    BookFormat.pdf,
    BookFormat.manga,
  ]) {
    test('${format.dbValue} 的 chapter 模式映射不进持久化进度（调用点②）', () async {
      final String key = 'p-${format.dbValue}';
      await seedBook(key, format);
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: key,
          sectionIndex: 137, // 第 137 页
          normCharOffset: 9990,
          updatedAt: 5000,
        ),
      );
      await repository.saveMappingIfAbsent(
        mediaType: TrackingMediaType.book,
        mediaKey: key,
        mediaTitle: key,
        kind: TrackingKind.novel,
        subjectId: 4242,
        subjectName: key,
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
      );
      final List<PersistedBookTrackingProgress> got =
          await repository.loadPersistedBookTrackingProgress(afterMs: 0);
      expect(
        got.where((PersistedBookTrackingProgress e) => e.mediaKey == key),
        isEmpty,
        reason: '按页翻的书没有章：整条不产出，'
            '否则第 137 页会被当成「已读 137 章」提交到用户的 Bangumi 记录',
      );
    });
  }

  test('PDF 的 volume 模式只在明确完成时把当前卷计入（持久化入口）', () async {
    const String key = 'persisted-pdf-volume';
    await seedBook(key, BookFormat.pdf);
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: key,
        sectionIndex: 137,
        normCharOffset: 5000,
        updatedAt: 5000,
      ),
    );
    await repository.saveMappingIfAbsent(
      mediaType: TrackingMediaType.book,
      mediaKey: key,
      mediaTitle: key,
      kind: TrackingKind.novel,
      subjectId: 2289,
      subjectName: key,
      progressMode: TrackingProgressMode.volume,
      progressOffset: 1,
    );

    List<PersistedBookTrackingProgress> got =
        await repository.loadPersistedBookTrackingProgress(afterMs: 0);
    PersistedBookTrackingProgress progress =
        got.singleWhere((PersistedBookTrackingProgress e) => e.mediaKey == key);
    expect(progress.localProgress, -1);
    expect(progress.completed, isFalse);

    await db.markEpubBookCompletedIfUnset(
      key,
      DateTime.fromMillisecondsSinceEpoch(6000),
    );
    got = await repository.loadPersistedBookTrackingProgress(afterMs: 0);
    progress =
        got.singleWhere((PersistedBookTrackingProgress e) => e.mediaKey == key);
    expect(progress.localProgress, 0);
    expect(progress.completed, isTrue);
  });

  test('epub 的 chapter 模式映射照常产出（调用点②没有误伤文字书）', () async {
    await seedBook('p-epub', BookFormat.epub);
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: 'p-epub',
        sectionIndex: 3,
        normCharOffset: 9990,
        updatedAt: 5000,
      ),
    );
    await repository.saveMappingIfAbsent(
      mediaType: TrackingMediaType.book,
      mediaKey: 'p-epub',
      mediaTitle: 'p-epub',
      kind: TrackingKind.novel,
      subjectId: 4243,
      subjectName: 'p-epub',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    final List<PersistedBookTrackingProgress> got =
        await repository.loadPersistedBookTrackingProgress(afterMs: 0);
    expect(
        got.where((PersistedBookTrackingProgress e) => e.mediaKey == 'p-epub'),
        isNotEmpty);
  });

  test('epub 仍照常产出章进度（止血没有误伤文字书）', () async {
    await seedBook('b-epub', BookFormat.epub);
    final int? progress = await repository.loadBookChapterProgress(
      bookKey: 'b-epub',
      fallbackProgress: 5,
    );
    expect(progress, isNotNull);
  });

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
