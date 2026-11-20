import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/download/manga_download_auto_ocr.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_files.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 假运行时：页表固定三页，取图返回真实 PNG 字节（尺寸随页序变，好核 manga.json）。
///
/// [OnlineMangaPageRef] 是密封类，假适配器借用数据形状最简单的
/// [InterconnectMangaPageRef] 当页引用——下载服务只看 `index`，不看里面是谁的。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  static const int pageCount = 3;

  /// 每页被取了几次（续跑 / 幂等断言用）。
  final Map<int, int> fetchCounts = <int, int>{};

  /// 某页要失败几次（按调用顺序递减）。
  final Map<int, int> failuresLeft = <int, int>{};

  /// 非空时取页先卡在这里（取消用）。
  Completer<void>? gate;

  /// 非空且对某页返回非 null 时，该页取页卡在它上面（只卡单页用）。
  Completer<void>? Function(int index)? gateFor;

  /// 非空时取页（过了 [gate] 之后）抛它造出的错误（失败分型用）。
  Exception Function(int index)? pageError;

  static Uint8List pngOf(int index) => Uint8List.fromList(
    img.encodePng(img.Image(width: 100 + index, height: 150 + index)),
  );

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  /// 页表被解析了几次。
  int resolveCount = 0;

  /// 运行时「进程代」：页引用记下解析时的代（借 `bookKey` 存），代变了（模拟桌面
  /// sidecar 重启）旧引用取页就抛 [OnlineMangaPageRefExpired]。
  int generation = 0;

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    resolveCount += 1;
    return <OnlineMangaPageRef>[
      for (int i = 0; i < pageCount; i++)
        InterconnectMangaPageRef(
          index: i,
          bookKey: 'fake-gen$generation',
          remoteIndex: i,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    fetchCounts[page.index] = (fetchCounts[page.index] ?? 0) + 1;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    final Completer<void>? pageGate = gateFor?.call(page.index);
    if (pageGate != null) await pageGate.future;
    if (page is InterconnectMangaPageRef &&
        page.bookKey != 'fake-gen$generation') {
      throw OnlineMangaPageRefExpired('stale page ${page.index}');
    }
    final Exception Function(int index)? error = pageError;
    if (error != null) throw error(page.index);
    final int left = failuresLeft[page.index] ?? 0;
    if (left > 0) {
      failuresLeft[page.index] = left - 1;
      throw StateError('boom page ${page.index}');
    }
    final Uint8List? override = pageBytes?.call(page.index);
    if (override != null) return override;
    return pngOf(page.index);
  }

  /// 非空且对某页返回非 null 时，用它替换该页的字节（上限 / 空页用）。
  Uint8List? Function(int index)? pageBytes;

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

/// 能取消在飞取页的假运行时（[OnlineMangaPageCancellable]），记下被取消的页序。
class _CancellableAdapter extends _FakeAdapter
    implements OnlineMangaPageCancellable {
  final List<int> cancelled = <int>[];

  @override
  Future<void> cancelChapterPages(Iterable<OnlineMangaPageRef> pages) async {
    cancelled.addAll(pages.map((OnlineMangaPageRef page) => page.index));
  }
}

/// 记录 update / stop 顺序的假保活（BUG-2714）。
class _RecordingKeepAlive implements DownloadKeepAlive {
  final List<String> events = <String>[];
  final List<int?> percents = <int?>[];

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    events.add('update:$title');
    percents.add(percent);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }
}

class _FakeOcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
    detectorReady: true,
    recognizerReady: true,
    diskBytes: 1,
    totalBytes: 1,
  );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<int> deleteModels() async => 0;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => const Stream<MangaOcrVolumeEvent>.empty();
}

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _chapters,
);

void main() {
  late Directory root;
  late FushiDatabase db;
  late _CancellableAdapter adapter;
  late OnlineMangaLibraryService library;
  late List<Duration> waits;
  late String bookKey;
  late String bookDir;

  MangaDownloadService build({
    MangaDownloadOcrHook? onChapterDownloaded,
    DownloadKeepAlive? keepAlive,
    int pageConcurrency = 4,
    Future<void> Function(Duration duration)? wait,
  }) => MangaDownloadService(
    database: db,
    serviceFor: (OnlineMangaRuntimeKind runtime) => library,
    onChapterDownloaded: onChapterDownloaded,
    keepAlive: keepAlive,
    pageConcurrency: pageConcurrency,
    wait:
        wait ??
        (Duration duration) async {
          waits.add(duration);
        },
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-manga-download-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _CancellableAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    waits = <Duration>[];
    final EpubBookRow row = await library.add(_entry());
    bookKey = row.bookKey;
    bookDir = row.extractDir;
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MangaDownloadJobRow> jobOf(String chapterKey) async =>
      (await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: chapterKey,
      ))!;

  test('入队 → worker 跑完：三张图落盘、manga.json 尺寸真实、行 done', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow queued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(queued.status, MangaDownloadJobStatus.queued);
    expect(queued.runtime, 'mihon');
    expect(queued.chapterTitle, 'Chapter 1');

    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.pagesDone, 3);
    expect(done.pagesTotal, 3);
    expect(done.completedAt, isNotNull);
    expect(done.lastError, isNull);

    final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
    for (int i = 1; i <= 3; i++) {
      final File page = File(
        p.join(chapterDir.path, 'images', 'page-00000$i.png'),
      );
      expect(page.existsSync(), isTrue, reason: 'page $i 必须落盘');
      expect(File('${page.path}.tmp').existsSync(), isFalse);
    }
    final MokuroPayload payload = parseMangaJson(
      mangaChapterJsonFile(chapterDir).readAsStringSync(),
    );
    expect(
      payload.images.map((MokuroImage image) => image.url).toList(),
      <String>[
        'images/page-000001.png',
        'images/page-000002.png',
        'images/page-000003.png',
      ],
    );
    expect(payload.images[0].size.width, 100);
    expect(payload.images[0].size.height, 150);
    expect(payload.images[2].size.width, 102);
    expect(payload.images[2].size.height, 152);
    expect(await isChapterDownloaded(bookDir, '/chapter/1'), isTrue);
    expect(waits, isEmpty);
    downloads.dispose();
  });

  test('单页连续失败 3 次 → failed + last_error，退避表被按序调用', () async {
    adapter.failuresLeft[1] = 99;
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow failed = await jobOf('/chapter/1');
    expect(failed.status, MangaDownloadJobStatus.failed);
    expect(failed.attemptCount, kMangaDownloadMaxAttempts);
    expect(failed.lastError, contains('boom page 1'));
    expect(waits, <Duration>[
      kMangaDownloadRetryBackoff[0],
      kMangaDownloadRetryBackoff[1],
    ]);
    expect(await isChapterDownloaded(bookDir, '/chapter/1'), isFalse);
    // 其余页只取一次：续跑认磁盘上已落地的页，不重下。
    expect(adapter.fetchCounts[0], 1);
    expect(adapter.fetchCounts[2], 1);
    expect(adapter.fetchCounts[1], kMangaDownloadMaxAttempts);
    downloads.dispose();
  });

  test('第 2 次成功 → done，退避只等了一次，已落地的页不重取', () async {
    adapter.failuresLeft[1] = 1;
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.attemptCount, 1);
    expect(done.lastError, isNull, reason: '成功后清掉上一次的错误');
    expect(waits, <Duration>[kMangaDownloadRetryBackoff[0]]);
    expect(adapter.fetchCounts[0], 1);
    expect(adapter.fetchCounts[1], 2);
    expect(adapter.fetchCounts[2], 1);
    downloads.dispose();
  });

  test('failed 后 retry → 重置 queued 并跑成 done', () async {
    adapter.failuresLeft[0] = 99;
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.failed);

    adapter.failuresLeft.clear();
    await downloads.retry(job.jobId);
    await downloads.whenIdle;
    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.lastError, isNull);
    downloads.dispose();
  });

  test('取消 running 的任务 → cancelled，半成品目录被删', () async {
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    // 等 worker 真的进到取页（第一页已被请求）。
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.running);
    final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
    expect(chapterDir.existsSync(), isTrue, reason: 'images/ 已建好');

    await downloads.cancel(job.jobId);
    adapter.gate!.complete();
    await downloads.whenIdle;

    expect(
      (await jobOf('/chapter/1')).status,
      MangaDownloadJobStatus.cancelled,
    );
    expect(chapterDir.existsSync(), isFalse, reason: '半成品目录必须删掉');
    downloads.dispose();
  });

  test('queued 的任务取消 → 直接 cancelled；再 enqueue 同章 → 重置成 queued', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: false,
    );
    await downloads.cancel(job.jobId);
    expect(
      (await jobOf('/chapter/2')).status,
      MangaDownloadJobStatus.cancelled,
    );
    final MangaDownloadJobRow again = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: true,
    );
    expect(again.jobId, job.jobId, reason: 'job_id 由身份三元组派生，稳定');
    expect(again.status, MangaDownloadJobStatus.queued);
    expect(again.autoOcr, isTrue);
    downloads.dispose();
  });

  test('取消（#2720）：只删未完成章的半成品，已下完的章原样保留', () async {
    final MangaDownloadService downloads = build();
    // 先把第 2 章完整下完。
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;
    final Directory doneDir = mangaChapterDirectory(bookDir, '/chapter/2');
    expect(await isChapterDownloaded(bookDir, '/chapter/2'), isTrue);

    // 第 1 章跑到一半（取页卡住）时取消。
    adapter.gate = Completer<void>();
    final MangaDownloadJobRow running = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    while ((adapter.fetchCounts[0] ?? 0) < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final Directory partialDir = mangaChapterDirectory(bookDir, '/chapter/1');
    expect(partialDir.existsSync(), isTrue);
    final int fetchesAtCancel = adapter.fetchCounts.values.fold<int>(
      0,
      (int sum, int count) => sum + count,
    );
    await downloads.cancel(running.jobId);
    adapter.gate!.complete();
    await downloads.whenIdle;

    expect(
      (await jobOf('/chapter/1')).status,
      MangaDownloadJobStatus.cancelled,
    );
    expect(partialDir.existsSync(), isFalse, reason: '半成品页 / .tmp 一并删掉');
    expect(
      adapter.fetchCounts.values.fold<int>(
        0,
        (int sum, int count) => sum + count,
      ),
      fetchesAtCancel,
      reason: '取消后不再发起新的取页',
    );
    expect(doneDir.existsSync(), isTrue, reason: '已下完的章不受取消影响');
    expect(await isChapterDownloaded(bookDir, '/chapter/2'), isTrue);
    downloads.dispose();
  });

  test('取消一条排队中、但章已完整在盘的任务 → 只改状态，不删章内容', () async {
    final MangaDownloadService first = build();
    final MangaDownloadJobRow job = await first.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await first.start();
    await first.whenIdle;
    first.dispose();
    expect(await isChapterDownloaded(bookDir, '/chapter/1'), isTrue);

    // 行被复位成 queued（如重下请求）但服务还没领到它。
    await db.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.queued,
      updatedAt: 1,
    );
    final MangaDownloadService second = build();
    await second.cancel(job.jobId);
    expect(
      (await jobOf('/chapter/1')).status,
      MangaDownloadJobStatus.cancelled,
    );
    expect(
      await isChapterDownloaded(bookDir, '/chapter/1'),
      isTrue,
      reason: '完整的章是用户内容，取消任务不能把它抹掉',
    );
    second.dispose();
  });

  test('重启：running 行复位成 queued 续跑', () async {
    final MangaDownloadService first = build();
    final MangaDownloadJobRow job = await first.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    // 模拟上一个进程死在 running：直接改状态，不起 worker。
    await db.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.running,
      updatedAt: 1,
    );
    first.dispose();

    final MangaDownloadService second = build();
    await second.start();
    await second.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    second.dispose();
  });

  test('同章重复入队幂等：done 且目录在 → 不重下、不重取', () async {
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(await db.listMangaDownloadJobs(), hasLength(1));
    await downloads.start();
    await downloads.whenIdle;
    expect(adapter.fetchCounts, <int, int>{0: 1, 1: 1, 2: 1});

    final MangaDownloadJobRow again = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(again.status, MangaDownloadJobStatus.done);
    await downloads.whenIdle;
    expect(adapter.fetchCounts, <int, int>{
      0: 1,
      1: 1,
      2: 1,
    }, reason: '已下载的章不该再打源');

    // 目录被删 → 判据失效 → 重新排队（worker 在跑，行可能已被立刻领走）。
    await deleteChapterDownload(bookDir, '/chapter/1');
    final MangaDownloadJobRow requeued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(
      requeued.status,
      anyOf(MangaDownloadJobStatus.queued, MangaDownloadJobStatus.running),
    );
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    expect(adapter.fetchCounts, <int, int>{
      0: 2,
      1: 2,
      2: 2,
    }, reason: '目录没了就得真的重下');
    downloads.dispose();
  });

  test('autoOcr 为真且引擎可用 → 注册表里出现本书的 OCR 任务', () async {
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final StreamController<MangaOcrBackgroundEvent> events =
        StreamController<MangaOcrBackgroundEvent>();
    addTearDown(events.close);
    final List<MangaOcrJobSpec> specs = <MangaOcrJobSpec>[];
    final MangaDownloadService downloads = build(
      onChapterDownloaded: (MangaDownloadedChapter chapter) async {
        await runAutoMangaOcrForDownloadedChapter(
          chapter: chapter,
          engines: MangaOcrWizardEngines(service: _FakeOcrService()),
          registry: registry,
          preference: MangaOcrEnginePreference.auto,
          lensLanguage: 'ja',
          buildEvents: (MangaOcrJobSpec spec) {
            specs.add(spec);
            return events.stream;
          },
        );
      },
    );
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: true,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaOcrRunningJob? running = registry.running(bookKey);
    expect(running, isNotNull);
    expect(running!.job.engine, MangaOcrEngineId.localOnnx);
    final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
    expect(running.job.managedDirectory, chapterDir.path);
    expect(running.mangaJsonPath, mangaChapterJsonFile(chapterDir).path);
    expect(
      specs.single.imageDirPath,
      chapterDir.path,
      reason: '从章目录起算，OCR 产物的 url 才是 images/page-…',
    );
    downloads.dispose();
    await registry.cancelAll();
  });

  test('autoOcr 但偏好是 Google Lens → 跳过（后台不能替用户同意上传）', () async {
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final MangaDownloadService downloads = build(
      onChapterDownloaded: (MangaDownloadedChapter chapter) async {
        final MangaOcrRunningJob? job =
            await runAutoMangaOcrForDownloadedChapter(
              chapter: chapter,
              engines: MangaOcrWizardEngines(service: _FakeOcrService()),
              registry: registry,
              preference: MangaOcrEnginePreference.googleLens,
              lensLanguage: 'ja',
              buildEvents: (_) => const Stream<MangaOcrBackgroundEvent>.empty(),
            );
        expect(job, isNull);
      },
    );
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: true,
    );
    await downloads.start();
    await downloads.whenIdle;
    expect(registry.running(bookKey), isNull);
    expect(
      (await jobOf('/chapter/1')).status,
      MangaDownloadJobStatus.done,
      reason: 'OCR 跳过不影响下载结果',
    );
    downloads.dispose();
  });

  group('下载保活（BUG-2714）', () {
    test('worker 开跑即保活、报页进度；两章连跑中间不撤，排空后撤一次', () async {
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final MangaDownloadService downloads = build(keepAlive: keepAlive);
      await downloads.enqueueChapters(
        entry: _entry(),
        chapters: _chapters,
        autoOcr: false,
      );
      expect(keepAlive.events, isEmpty, reason: '未 start 不该挂保活');

      await downloads.start();
      await downloads.whenIdle;

      expect(keepAlive.events.first, 'update:Fixture series');
      expect(keepAlive.events.last, 'stop');
      expect(
        keepAlive.events.where((String e) => e == 'stop'),
        hasLength(1),
        reason: '队列没排空之前不能撤（后台里撤了就再也拉不起前台服务）',
      );
      expect(keepAlive.percents, contains(100));
      downloads.dispose();
      expect(
        keepAlive.events.where((String e) => e == 'stop'),
        hasLength(1),
        reason: '已撤过，dispose 不重复 stop',
      );
    });

    test('跑到一半 dispose → 撤保活', () async {
      adapter.gate = Completer<void>();
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final MangaDownloadService downloads = build(keepAlive: keepAlive);
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(keepAlive.events, isNot(contains('stop')));

      downloads.dispose();
      expect(keepAlive.events.last, 'stop');
      adapter.gate!.complete();
      await downloads.whenIdle;
      expect(keepAlive.events.where((String e) => e == 'stop'), hasLength(1));
    });
  });

  // 拍板台 7LwxAtJ6r0：漫画下载队列可暂停 / 恢复（半成品留着续跑），整批按书操作。
  group('暂停 / 恢复', () {
    test('下载中暂停 → paused，已落地的页保留、不再取新页；恢复后只补剩下的页', () async {
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build(pageConcurrency: 1);
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final Future<void> pausing = downloads.pause(job.jobId);
      adapter.gate!.complete();
      adapter.gate = null;
      await pausing;
      await downloads.whenIdle;

      final MangaDownloadJobRow paused = await jobOf('/chapter/1');
      expect(paused.status, MangaDownloadJobStatus.paused);
      expect(paused.pagesDone, 1);
      expect(adapter.fetchCounts, <int, int>{0: 1}, reason: '暂停后不再发起新的取页');
      final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
      expect(chapterDir.existsSync(), isTrue, reason: '暂停不删半成品');
      expect(await isChapterDownloaded(bookDir, '/chapter/1'), isFalse);

      await downloads.resume(job.jobId);
      await downloads.whenIdle;
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
      expect(adapter.fetchCounts, <int, int>{
        0: 1,
        1: 1,
        2: 1,
      }, reason: '已落地的第 1 页不重取');
      downloads.dispose();
    });

    test('排队中暂停 → worker 跳过它；暂停跨重启保持；恢复后排回去跑完', () async {
      final MangaDownloadService first = build();
      final MangaDownloadJobRow held = await first.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await first.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.first,
        autoOcr: false,
      );
      await first.pause(held.jobId);
      await first.start();
      await first.whenIdle;
      expect((await jobOf('/chapter/2')).status, MangaDownloadJobStatus.done);
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.paused);
      first.dispose();

      final MangaDownloadService second = build();
      await second.start();
      await second.whenIdle;
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.paused,
        reason: '重启不把暂停的任务复位成排队',
      );
      await second.resume(held.jobId);
      await second.whenIdle;
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
      second.dispose();
    });

    test('pauseAll / resumeAll / cancelAll 只作用于给定的书', () async {
      final MangaDownloadService downloads = build();
      await downloads.enqueueChapters(
        entry: _entry(),
        chapters: _chapters,
        autoOcr: false,
      );
      final String otherJob = (await downloads.enqueueMokuroVolume(
        seriesName: 'Other',
        volumeName: '01',
      )).row.jobId;

      await downloads.pauseAll(bookKey: bookKey);
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.paused);
      expect((await jobOf('/chapter/2')).status, MangaDownloadJobStatus.paused);
      expect(
        (await db.getMangaDownloadJob(otherJob))!.status,
        MangaDownloadJobStatus.queued,
        reason: '别的作品不受影响',
      );

      await downloads.resumeAll(bookKey: bookKey);
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.queued);
      expect((await jobOf('/chapter/2')).status, MangaDownloadJobStatus.queued);

      await downloads.pause((await jobOf('/chapter/1')).jobId);
      await downloads.cancelAll(bookKey: bookKey);
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.cancelled,
        reason: '暂停的任务也能取消',
      );
      expect(
        (await jobOf('/chapter/2')).status,
        MangaDownloadJobStatus.cancelled,
      );
      expect(
        (await db.getMangaDownloadJob(otherJob))!.status,
        MangaDownloadJobStatus.queued,
      );
      downloads.dispose();
    });

    test('取消暂停中的任务 → cancelled 并删半成品', () async {
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build(pageConcurrency: 1);
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final Future<void> pausing = downloads.pause(job.jobId);
      adapter.gate!.complete();
      adapter.gate = null;
      await pausing;
      await downloads.whenIdle;
      final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
      expect(chapterDir.existsSync(), isTrue);

      await downloads.cancel(job.jobId);
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.cancelled,
      );
      expect(chapterDir.existsSync(), isFalse, reason: '取消照样删半成品');
      downloads.dispose();
    });

    test('服务还没 start 时暂停上次进程留下的 running 行 → 直接 paused，start 不复活它', () async {
      final MangaDownloadService first = build();
      final MangaDownloadJobRow job = await first.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      first.dispose();
      await db.updateMangaDownloadJobStatus(
        job.jobId,
        status: MangaDownloadJobStatus.running,
        updatedAt: 1,
      );

      final MangaDownloadService second = build();
      await second.pause(job.jobId);
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.paused);
      await second.start();
      await second.whenIdle;
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.paused);
      expect(adapter.fetchCounts, isEmpty);
      second.dispose();
    });
  });

  // BUG-4906（manga-12）：暂停 / 取消传不到在途请求与退避；失败不分型一律退避。
  group('中止立即生效与失败分型（BUG-4906）', () {
    const Duration guard = Duration(seconds: 5);

    Future<void> untilAllPagesInFlight() async {
      while ((adapter.fetchCounts[_FakeAdapter.pageCount - 1] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    List<String> landedPages() {
      final Directory images = Directory(
        p.join(mangaChapterDirectory(bookDir, '/chapter/1').path, 'images'),
      );
      if (!images.existsSync()) return const <String>[];
      return images
          .listSync()
          .whereType<File>()
          .map((File file) => p.basename(file.path))
          .toList();
    }

    test('取页卡住时暂停立即返回：在飞请求交给运行时取消，晚到的字节不落盘；恢复后补齐', () async {
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      await untilAllPagesInFlight();

      // 修复前：pause 要等在飞的取页自己完成（运行时侧最长 2 分钟），这里永远等不到。
      await downloads.pause(job.jobId).timeout(guard);
      await downloads.whenIdle.timeout(guard);

      final MangaDownloadJobRow paused = await jobOf('/chapter/1');
      expect(paused.status, MangaDownloadJobStatus.paused);
      expect(paused.pagesDone, 0);
      expect(adapter.cancelled.toSet(), <int>{0, 1, 2});

      // 被放弃的请求晚到：字节不能再写进章目录（暂停的半成品只认已落地的页）。
      adapter.gate!.complete();
      adapter.gate = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(landedPages(), isEmpty);

      await downloads.resume(job.jobId);
      await downloads.whenIdle.timeout(guard);
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
      expect(await isChapterDownloaded(bookDir, '/chapter/1'), isTrue);
      downloads.dispose();
    });

    test('取页卡住时取消立即收尾：cancelled、半成品删掉、在飞请求被取消', () async {
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      await untilAllPagesInFlight();

      await downloads.cancel(job.jobId);
      await downloads.whenIdle.timeout(guard);

      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.cancelled,
      );
      expect(adapter.cancelled.toSet(), <int>{0, 1, 2});
      final Directory chapterDir = mangaChapterDirectory(bookDir, '/chapter/1');
      expect(chapterDir.existsSync(), isFalse);

      adapter.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chapterDir.existsSync(), isFalse, reason: '晚到的字节不能把目录建回来');
      downloads.dispose();
    });

    test('退避等待中暂停立即生效（退避注入口仍收到退避表）', () async {
      adapter.failuresLeft[0] = 99;
      final List<Duration> recorded = <Duration>[];
      final MangaDownloadService downloads = build(
        // 永不结束的退避：修复前暂停要等它走完。
        wait: (Duration duration) {
          recorded.add(duration);
          return Completer<void>().future;
        },
      );
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while (recorded.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await downloads.pause(job.jobId).timeout(guard);
      await downloads.whenIdle.timeout(guard);

      final MangaDownloadJobRow paused = await jobOf('/chapter/1');
      expect(paused.status, MangaDownloadJobStatus.paused);
      expect(paused.attemptCount, 1);
      expect(recorded, <Duration>[kMangaDownloadRetryBackoff[0]]);
      downloads.dispose();
    });

    for (final ({String name, Exception Function(int) error}) failure
        in <({String name, Exception Function(int) error})>[
          (
            name: '要过 Cloudflare 验证（挑战包在运行时失败的 cause 里，按类型认）',
            error: (int index) => OnlineMangaUnavailable(
              OnlineMangaUnavailableReason.runtimeFailure,
              'Mihon fetchImage failed',
              cause: MihonCloudflareChallengeException(
                Uri.parse('https://source.example/'),
              ),
              stage: 'pages',
            ),
          ),
          (
            name: '源已停用',
            error: (int index) => const OnlineMangaUnavailable(
              OnlineMangaUnavailableReason.sourceDisabled,
              'The source is disabled',
            ),
          ),
        ]) {
      test('${failure.name} → 不退避，直接 failed', () async {
        adapter.pageError = failure.error;
        final MangaDownloadService downloads = build(pageConcurrency: 1);
        await downloads.enqueueChapter(
          entry: _entry(),
          chapter: _chapters.last,
          autoOcr: false,
        );
        await downloads.start();
        await downloads.whenIdle;

        final MangaDownloadJobRow failed = await jobOf('/chapter/1');
        expect(failed.status, MangaDownloadJobStatus.failed);
        expect(failed.attemptCount, 1);
        expect(waits, isEmpty, reason: '再试也一样的失败不该白等退避');
        expect(adapter.fetchCounts, <int, int>{0: 1});
        downloads.dispose();
      });
    }

    test('章已从源的章节表里下架（前置条件）→ 不退避，直接 failed', () async {
      const OnlineMangaChapter gone = OnlineMangaChapter(
        key: '/chapter/gone',
        name: 'Gone',
        number: 9,
        raw: <String, Object?>{'url': '/chapter/gone'},
      );
      final MangaDownloadService downloads = build();
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: gone,
        autoOcr: false,
      );
      await downloads.start();
      await downloads.whenIdle;

      final MangaDownloadJobRow failed = await jobOf('/chapter/gone');
      expect(failed.status, MangaDownloadJobStatus.failed);
      expect(failed.attemptCount, 1);
      expect(failed.lastError, contains('no longer listed'));
      expect(waits, isEmpty);
      downloads.dispose();
    });

    test('一般的运行时失败（分不出是否瞬时）仍照退避表重试', () async {
      adapter.pageError = (int index) => const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'SocketException: Connection reset',
      );
      final MangaDownloadService downloads = build(pageConcurrency: 1);
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      await downloads.whenIdle;

      final MangaDownloadJobRow failed = await jobOf('/chapter/1');
      expect(failed.status, MangaDownloadJobStatus.failed);
      expect(failed.attemptCount, kMangaDownloadMaxAttempts);
      expect(waits, <Duration>[
        kMangaDownloadRetryBackoff[0],
        kMangaDownloadRetryBackoff[1],
      ]);
      downloads.dispose();
    });
  });

  // manga-27：直读与下载共用一段「字节 → 暂存 → 改名」，单页上限同一口径。
  test('已取完的页不在中止令牌上留监听（否则每页字节被攥到任务结束）', () async {
    final Completer<void> lastPage = Completer<void>();
    adapter.gateFor = (int index) =>
        index == _FakeAdapter.pageCount - 1 ? lastPage : null;
    final MangaDownloadService downloads = build(pageConcurrency: 1);
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    while ((adapter.fetchCounts[_FakeAdapter.pageCount - 1] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // 前两页与页表都已取完，只剩最后一页在飞：令牌上只该挂它这一个监听。
    expect(downloads.debugActiveTripListenerCount, 1);
    lastPage.complete();
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    downloads.dispose();
  });

  // 路线图 #3722 c43 遗留：整章下载途中 sidecar 重启，旧页表全部失效。原来按一般
  // 失败退避（白等 2 秒）后整章重来；现在经 OnlineMangaChapterPageRefs 就地换新引用。
  test('运行时重启让页引用失效：就地重解析页表接着取，不退避重来', () async {
    final Completer<void> restart = Completer<void>();
    adapter.gateFor = (int index) => index == 0 ? null : restart;
    final MangaDownloadService downloads = build(pageConcurrency: 1);
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    while ((adapter.fetchCounts[1] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    adapter.generation = 1;
    restart.complete();
    await downloads.whenIdle;

    final MangaDownloadJobRow job = await jobOf('/chapter/1');
    expect(job.status, MangaDownloadJobStatus.done);
    expect(job.attemptCount, 0, reason: '没有记任何一次失败');
    expect(waits, isEmpty, reason: '没有退避');
    expect(adapter.resolveCount, 2, reason: '页表只多解析一次');
    downloads.dispose();
  });

  test('下载侧也拒超过单页上限的页（与在线直读同一口径），不落盘', () async {
    adapter.pageBytes = (int index) =>
        index == 1 ? Uint8List(kMangaPageMaximumBytes + 1) : null;
    final MangaDownloadService downloads = build(pageConcurrency: 1);
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow failed = await jobOf('/chapter/1');
    expect(failed.status, MangaDownloadJobStatus.failed);
    expect(failed.lastError, contains('PAGE_TOO_LARGE'));
    // 确定性失败：同一页再取还是超限，不该退避重试（每次都白下 100 MiB 以上）。
    expect(failed.attemptCount, 1);
    expect(adapter.fetchCounts[1], 1);
    final Directory images = Directory(
      p.join(mangaChapterDirectory(bookDir, '/chapter/1').path, 'images'),
    );
    final List<String> names = images
        .listSync()
        .map((FileSystemEntity entity) => p.basename(entity.path))
        .toList();
    expect(
      names.where((String name) => name.startsWith('page-000002')),
      isEmpty,
      reason: '超限的页不能落盘（暂存也不能留）',
    );
    downloads.dispose();
  });
}
