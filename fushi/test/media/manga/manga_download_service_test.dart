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
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
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
          OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async =>
      <OnlineMangaPageRef>[
        for (int i = 0; i < pageCount; i++)
          InterconnectMangaPageRef(index: i, bookKey: 'fake', remoteIndex: i),
      ];

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    fetchCounts[page.index] = (fetchCounts[page.index] ?? 0) + 1;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    final int left = failuresLeft[page.index] ?? 0;
    if (left > 0) {
      failuresLeft[page.index] = left - 1;
      throw StateError('boom page ${page.index}');
    }
    return pngOf(page.index);
  }

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
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
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
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
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late List<Duration> waits;
  late String bookKey;
  late String bookDir;

  MangaDownloadService build({MangaDownloadOcrHook? onChapterDownloaded}) =>
      MangaDownloadService(
        database: db,
        serviceFor: (OnlineMangaRuntimeKind runtime) => library,
        onChapterDownloaded: onChapterDownloaded,
        wait: (Duration duration) async {
          waits.add(duration);
        },
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-manga-download-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FakeAdapter();
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
        payload.images.map((MokuroImage image) => image.url).toList(), <String>[
      'images/page-000001.png',
      'images/page-000002.png',
      'images/page-000003.png',
    ]);
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
        (await jobOf('/chapter/1')).status, MangaDownloadJobStatus.cancelled);
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
        (await jobOf('/chapter/2')).status, MangaDownloadJobStatus.cancelled);
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
    expect(adapter.fetchCounts, <int, int>{0: 1, 1: 1, 2: 1},
        reason: '已下载的章不该再打源');

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
    expect(adapter.fetchCounts, <int, int>{0: 2, 1: 2, 2: 2},
        reason: '目录没了就得真的重下');
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
    expect(specs.single.imageDirPath, chapterDir.path,
        reason: '从章目录起算，OCR 产物的 url 才是 images/page-…');
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
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done,
        reason: 'OCR 跳过不影响下载结果');
    downloads.dispose();
  });
}
