import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/ocr/manga_ai_ocr_stream.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 大模型识别作为整卷任务的跟随步骤（[MangaAiOcrJobFollower]，注册表驱动）：
/// finished 立即落本地结果并释放名额，大模型在任务之外收尾、按页读改写书根
/// manga.json 并补发；任何失败 / 取消都保留本地结果。
void main() {
  late Directory dir;
  late String mangaJsonPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ai_ocr_follower_');
    for (final String name in <String>['p1.png', 'p2.png']) {
      await File(
        p.join(dir.path, name),
      ).writeAsBytes(img.encodePng(img.Image(width: 200, height: 100)));
    }
    mangaJsonPath = p.join(dir.path, 'manga.json');
  });
  tearDown(() => dir.delete(recursive: true));

  final AiProviderConfig provider = AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
  );

  MokuroImage localPage(String url, String text) => MokuroImage(
    url: url,
    size: const MokuroSize(200, 100),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: const MokuroRect.fromLTRB(10, 10, 50, 90),
        isVertical: true,
        fontSize: 20,
        zIndex: 0,
        lines: <String>[text],
        confidence: 0.3,
      ),
    ],
  );

  /// 引擎产物（`manga_ocr_out/manga.json`），finished 事件指向它。
  Future<String> writeResult(List<MokuroImage> pages) async {
    final File out = File(p.join(dir.path, 'manga_ocr_out', 'manga.json'));
    await out.parent.create(recursive: true);
    await out.writeAsString(
      jsonEncode(mangaPayloadToJson(MokuroPayload(images: pages))),
    );
    return out.path;
  }

  MokuroPayload readBookJson() =>
      parseMangaJson(File(mangaJsonPath).readAsStringSync());

  ({MangaAiOcrJobFollower follower, _GatedClients clients}) follower({
    required String reply,
    bool discardCache = false,
  }) {
    final _GatedClients clients = _GatedClients(reply);
    return (
      follower: MangaAiOcrJobFollower(
        imageDirPath: dir.path,
        refiner: MangaAiOcrRefiner(
          provider: provider,
          mode: MangaAiOcrMode.lowConfidence,
          clientFactory: clients.next,
        ),
        discardCache: discardCache,
      ),
      clients: clients,
    );
  }

  MangaOcrBackgroundJob job(
    StreamController<MangaOcrBackgroundEvent> source,
    MangaOcrJobFollower follower, {
    String bookKey = 'book',
  }) => MangaOcrBackgroundJob(
    bookKey: bookKey,
    managedDirectory: dir.path,
    engine: MangaOcrEngineId.localOnnx,
    events: source.stream,
    follower: follower,
  );

  test('finished 不等大模型：本地结果先落盘、任务结束；重读回来再按页回写并补发', () async {
    final String resultPath = await writeResult(<MokuroImage>[
      localPage('p1.png', '期限の悪い'),
    ]);
    final f = follower(reply: '{"blocks":[{"id":1,"text":"機嫌の悪い"}]}');
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final StreamController<MangaOcrBackgroundEvent> source =
        StreamController<MangaOcrBackgroundEvent>();
    final MangaOcrRunningJob running = registry.start(
      job: job(source, f.follower),
      mangaJsonPath: mangaJsonPath,
    );
    final List<MangaOcrBackgroundEvent> seen = <MangaOcrBackgroundEvent>[];
    final Completer<void> observersDone = Completer<void>();
    running.events.listen(seen.add, onDone: observersDone.complete);

    source.add(
      MangaOcrBackgroundEvent.progress(
        pagesDone: 1,
        pagesTotal: 1,
        pageIndex: 0,
        page: localPage('p1.png', '期限の悪い'),
      ),
    );
    await f.clients.firstStarted;
    source.add(
      MangaOcrBackgroundEvent.finished(
        pagesTotal: 1,
        resultPath: resultPath,
        external: false,
      ),
    );
    await source.close();
    // 大模型请求还挂着：任务照样结束（名额释放点），本地结果已在盘上。
    await running.whenEnded.timeout(const Duration(seconds: 5));
    expect(seen.where((MangaOcrBackgroundEvent e) => e.finished), hasLength(1));
    expect(readBookJson().images.single.blocks.single.lines, <String>['期限の悪い']);
    expect(registry.running('book'), isNull);
    expect(observersDone.isCompleted, isFalse, reason: '跟随步骤收尾前观察者流不关');

    f.clients.releaseAll();
    await f.follower.done.timeout(const Duration(seconds: 5));
    await observersDone.future.timeout(const Duration(seconds: 5));
    final MokuroBlock written = readBookJson().images.single.blocks.single;
    expect(written.lines, <String>['機嫌の悪い']);
    expect(written.aiRecognized, isTrue);
    final MangaOcrBackgroundEvent update = seen.last;
    expect(update.finished, isFalse);
    expect(update.pageIndex, 0);
    expect(update.page!.blocks.single.lines, <String>['機嫌の悪い']);
    expect(f.clients.calls, 1, reason: '同一页只送一次');
  });

  test('全局名额在大模型收尾前就释放：下一卷不等上一卷的大模型', () async {
    final String resultPath = await writeResult(<MokuroImage>[
      localPage('p1.png', '期限の悪い'),
    ]);
    final f = follower(reply: '{"blocks":[{"id":1,"text":"機嫌の悪い"}]}');
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
      maxConcurrentJobs: () => 1,
    );
    final StreamController<MangaOcrBackgroundEvent> first =
        StreamController<MangaOcrBackgroundEvent>();
    final StreamController<MangaOcrBackgroundEvent> second =
        StreamController<MangaOcrBackgroundEvent>();
    final MangaOcrRunningJob? a = await registry.enqueue(
      job: job(first, f.follower, bookKey: 'a'),
      mangaJsonPath: mangaJsonPath,
    );
    final Future<MangaOcrRunningJob?> b = registry.enqueue(
      job: MangaOcrBackgroundJob(
        bookKey: 'b',
        managedDirectory: p.join(dir.path, 'other'),
        engine: MangaOcrEngineId.localOnnx,
        events: second.stream,
      ),
      mangaJsonPath: p.join(dir.path, 'other.json'),
    );
    expect(a, isNotNull);
    // 外部 mokuro 形状：进度不带页，大模型全部在落盘之后。
    first.add(
      MangaOcrBackgroundEvent.finished(
        pagesTotal: 1,
        resultPath: resultPath,
        external: false,
      ),
    );
    await first.close();
    await f.clients.firstStarted.timeout(const Duration(seconds: 5));
    final MangaOcrRunningJob? started = await b.timeout(
      const Duration(seconds: 5),
    );
    expect(started, isNotNull, reason: '第二卷在第一卷的大模型请求挂着时就该开跑');
    f.clients.releaseAll();
    await f.follower.done.timeout(const Duration(seconds: 5));
    expect(readBookJson().images.single.blocks.single.lines, <String>['機嫌の悪い']);
    await second.close();
  });

  test('重读期间整卷被重新识别过：不拿旧页的重读覆盖新结果', () async {
    final String resultPath = await writeResult(<MokuroImage>[
      localPage('p1.png', '期限の悪い'),
    ]);
    final f = follower(reply: '{"blocks":[{"id":1,"text":"機嫌の悪い"}]}');
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final StreamController<MangaOcrBackgroundEvent> source =
        StreamController<MangaOcrBackgroundEvent>();
    final MangaOcrRunningJob running = registry.start(
      job: job(source, f.follower),
      mangaJsonPath: mangaJsonPath,
    );
    running.events.listen((_) {});
    source.add(
      MangaOcrBackgroundEvent.finished(
        pagesTotal: 1,
        resultPath: resultPath,
        external: false,
      ),
    );
    await source.close();
    await f.clients.firstStarted.timeout(const Duration(seconds: 5));
    await runExclusiveOnMangaJson<void>(
      mangaJsonPath,
      () => writeMangaJsonAtomically(
        mangaJsonPath,
        MokuroPayload(images: <MokuroImage>[localPage('p1.png', '新しい')]),
      ),
    );
    f.clients.releaseAll();
    await f.follower.done.timeout(const Duration(seconds: 5));
    expect(readBookJson().images.single.blocks.single.lines, <String>['新しい']);
  });

  test('删书 / 取消本书：收尾中的大模型被中止，不再写盘', () async {
    final String resultPath = await writeResult(<MokuroImage>[
      localPage('p1.png', '期限の悪い'),
      localPage('p2.png', '元気'),
    ]);
    final f = follower(reply: '{"blocks":[{"id":1,"text":"機嫌の悪い"}]}');
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final StreamController<MangaOcrBackgroundEvent> source =
        StreamController<MangaOcrBackgroundEvent>();
    final MangaOcrRunningJob running = registry.start(
      job: job(source, f.follower),
      mangaJsonPath: mangaJsonPath,
    );
    running.events.listen((_) {});
    source.add(
      MangaOcrBackgroundEvent.finished(
        pagesTotal: 2,
        resultPath: resultPath,
        external: false,
      ),
    );
    await source.close();
    await f.clients.firstStarted.timeout(const Duration(seconds: 5));
    await running.whenEnded;

    await registry.cancel('book');
    await f.follower.done.timeout(const Duration(seconds: 5));
    expect(f.clients.lastClosed, isTrue, reason: '在途请求被中止');
    expect(f.clients.calls, 1, reason: '第二页不再送');
    expect(readBookJson().images.first.blocks.single.lines, <String>['期限の悪い']);
  });

  test('请求失败：本地结果原样，任务照常结束', () async {
    final String resultPath = await writeResult(<MokuroImage>[
      localPage('p1.png', '期限の悪い'),
    ]);
    final f = follower(reply: 'not json at all');
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final StreamController<MangaOcrBackgroundEvent> source =
        StreamController<MangaOcrBackgroundEvent>();
    final MangaOcrRunningJob running = registry.start(
      job: job(source, f.follower),
      mangaJsonPath: mangaJsonPath,
    );
    final List<MangaOcrBackgroundEvent> seen = <MangaOcrBackgroundEvent>[];
    running.events.listen(seen.add);
    f.clients.releaseAll();
    source.add(
      MangaOcrBackgroundEvent.finished(
        pagesTotal: 1,
        resultPath: resultPath,
        external: false,
      ),
    );
    await source.close();
    await f.follower.done.timeout(const Duration(seconds: 5));
    expect(seen, hasLength(1));
    expect(seen.single.finished, isTrue);
    expect(readBookJson().images.single.blocks.single.lines, <String>['期限の悪い']);
  });

  // 用户本机两天 78 条 `MangaAiOcr.refinePage: AiChatFailure: rate_limited` 错误：
  // 限流 / 网络 / 5xx 是预期降级（保留本地文字），只该记诊断；400 这类配置问题照记错误。
  for (final ({String failure, bool isError}) c
      in <({String failure, bool isError})>[
        (failure: 'rate_limited', isError: false),
        (failure: 'network_error', isError: false),
        (failure: 'http_400', isError: true),
      ]) {
    test('重读失败 ${c.failure}：${c.isError ? '记错误' : '只记诊断，不进错误日志'}', () async {
      final String resultPath = await writeResult(<MokuroImage>[
        localPage('p1.png', '期限の悪い'),
        localPage('p2.png', '期限の悪い'),
      ]);
      final MangaAiOcrJobFollower follower = MangaAiOcrJobFollower(
        imageDirPath: dir.path,
        refiner: MangaAiOcrRefiner(
          provider: provider,
          mode: MangaAiOcrMode.lowConfidence,
          clientFactory: () => _FailingClient(c.failure),
        ),
        discardCache: false,
      );
      final ErrorLogService log = ErrorLogService.instance;
      final int errorsBefore = log.entries.length;
      final int diagnosticsBefore = log.diagnosticEntries.length;
      follower.onPersisted(
        resultPath,
        parseMangaJson(await File(resultPath).readAsString()),
      );
      await follower.done.timeout(const Duration(seconds: 5));
      final Iterable<ErrorLogEntry> newErrors = log.entries
          .skip(errorsBefore)
          .where((ErrorLogEntry e) => e.source == 'MangaAiOcr.refinePage');
      final Iterable<ErrorLogEntry> newDiagnostics = log.diagnosticEntries
          .skip(diagnosticsBefore)
          .where((ErrorLogEntry e) => e.source == 'MangaAiOcr.refinePage');
      if (c.isError) {
        expect(newErrors, hasLength(1));
        expect(newDiagnostics, isEmpty);
      } else {
        expect(newErrors, isEmpty);
        expect(newDiagnostics, hasLength(1), reason: '两页失败也只记一条');
      }
    });
  }

  test('重新识别（discardCache）先清掉本卷大模型缓存', () async {
    final MangaAiOcrCache cache = MangaAiOcrCache.forVolume(dir.path, provider);
    await cache.storeAll(<String, String>{'stale': 'x'});
    final String resultPath = await writeResult(<MokuroImage>[
      localPage('p1.png', '期限の悪い'),
    ]);
    final f = follower(
      reply: '{"blocks":[{"id":1,"text":"機嫌の悪い"}]}',
      discardCache: true,
    );
    f.clients.releaseAll();
    f.follower.onPersisted(
      resultPath,
      parseMangaJson(await File(resultPath).readAsString()),
    );
    await f.follower.done.timeout(const Duration(seconds: 5));
    expect(
      await MangaAiOcrCache.forVolume(dir.path, provider).lookup('stale'),
      isNull,
    );
  });

  group('落盘后的回写攒批（manga-7）', () {
    const String reply = '{"blocks":[{"id":1,"text":"機嫌の悪い"}]}';
    const List<String> names = <String>['p1.png', 'p2.png', 'p3.png', 'p4.png'];

    /// 每页一张颜色不同的图（大模型缓存按裁图字节键控，同图会直接命中缓存）。
    Future<void> writeDistinctPages() async {
      for (int i = 0; i < names.length; i++) {
        final img.Image image = img.Image(width: 200, height: 100);
        img.fill(image, color: img.ColorRgb8(40 * (i + 1), 10, 200));
        await File(
          p.join(dir.path, names[i]),
        ).writeAsBytes(img.encodePng(image));
      }
    }

    Future<void> writeBookJson(List<MokuroImage> pages) =>
        File(mangaJsonPath).writeAsString(
          jsonEncode(mangaPayloadToJson(MokuroPayload(images: pages))),
        );

    List<String> diskLines() => <String>[
      for (final MokuroImage image in readBookJson().images)
        '${image.url}:${image.blocks.single.lines.single}',
    ];

    ({MangaAiOcrJobFollower follower, _SteppedClients clients}) stepped({
      required int flushPageCount,
      required Duration flushInterval,
      int? failFrom,
    }) {
      final _SteppedClients clients = _SteppedClients(
        reply,
        failFrom: failFrom,
      );
      return (
        follower: MangaAiOcrJobFollower(
          imageDirPath: dir.path,
          refiner: MangaAiOcrRefiner(
            provider: provider,
            mode: MangaAiOcrMode.lowConfidence,
            clientFactory: clients.next,
          ),
          flushPageCount: flushPageCount,
          flushInterval: flushInterval,
        ),
        clients: clients,
      );
    }

    /// 在记下「时长为 [interval] 的计时器」的 zone 里跑 [body]：跟随步骤的定时
    /// 冲刷是它建的唯一一种这个时长的计时器。
    void trackingFlushTimers(
      Duration interval,
      List<Timer> created,
      void Function() body,
    ) {
      runZoned<void>(
        body,
        zoneSpecification: ZoneSpecification(
          createTimer:
              (
                Zone self,
                ZoneDelegate parent,
                Zone zone,
                Duration duration,
                void Function() callback,
              ) {
                final Timer timer = parent.createTimer(
                  zone,
                  duration,
                  callback,
                );
                if (duration == interval) created.add(timer);
                return timer;
              },
        ),
      );
    }

    test('攒够页数才整份读改写一次，收尾冲刷剩下的；补发按盘上序号', () async {
      await writeDistinctPages();
      final List<MokuroImage> pages = <MokuroImage>[
        localPage('p1.png', '一'),
        localPage('p2.png', '二'),
        localPage('p3.png', '三'),
      ];
      await writeBookJson(pages);
      final s = stepped(
        flushPageCount: 2,
        flushInterval: const Duration(hours: 1),
      );
      final List<MangaOcrPageUpdate> updates = <MangaOcrPageUpdate>[];
      s.follower.updates.listen(updates.add);
      s.follower.onPersisted(mangaJsonPath, MokuroPayload(images: pages));

      // 第 1 页改好：只进待写批，不写盘、不补发。
      await s.clients.started(1).timeout(const Duration(seconds: 5));
      s.clients.release(1);
      await s.clients.started(2).timeout(const Duration(seconds: 5));
      expect(diskLines(), <String>['p1.png:一', 'p2.png:二', 'p3.png:三']);
      expect(updates, isEmpty);

      // 期间盘上页序变了（内容没变）：补发要用盘上的序号。
      await runExclusiveOnMangaJson<void>(
        mangaJsonPath,
        () => writeMangaJsonAtomically(
          mangaJsonPath,
          MokuroPayload(images: <MokuroImage>[pages[1], pages[0], pages[2]]),
        ),
      );

      // 第 2 页改好：攒够 2 页，一次写进去两页。
      s.clients.release(2);
      await s.clients.started(3).timeout(const Duration(seconds: 5));
      expect(diskLines(), <String>['p2.png:機嫌の悪い', 'p1.png:機嫌の悪い', 'p3.png:三']);
      await pumpEventQueue();
      expect(
        <String>[
          for (final MangaOcrPageUpdate u in updates)
            '${u.pageIndex}:${u.page.url}',
        ],
        <String>['1:p1.png', '0:p2.png'],
      );

      // 第 3 页不够一批：收尾冲刷。
      s.clients.release(3);
      await s.follower.done.timeout(const Duration(seconds: 5));
      expect(diskLines().last, 'p3.png:機嫌の悪い');
      await pumpEventQueue();
      expect(updates, hasLength(3));
      expect(updates.last.pageIndex, 2);
      expect(s.clients.calls, 3);
    });

    test('凑不够页数：最早一页等满间隔也冲刷，不等下一页的大模型回来', () async {
      await writeDistinctPages();
      final List<MokuroImage> pages = <MokuroImage>[
        localPage('p1.png', '一'),
        localPage('p2.png', '二'),
      ];
      await writeBookJson(pages);
      final s = stepped(
        flushPageCount: 100,
        flushInterval: const Duration(milliseconds: 50),
      );
      final List<MangaOcrPageUpdate> updates = <MangaOcrPageUpdate>[];
      s.follower.updates.listen(updates.add);
      s.follower.onPersisted(mangaJsonPath, MokuroPayload(images: pages));
      await s.clients.started(1).timeout(const Duration(seconds: 5));
      s.clients.release(1);
      await s.clients.started(2).timeout(const Duration(seconds: 5));

      // 第 2 页的请求一直挂着：第 1 页靠间隔落盘并补发。
      final Stopwatch waited = Stopwatch()..start();
      while (updates.isEmpty && waited.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(updates.single.pageIndex, 0);
      expect(diskLines(), <String>['p1.png:機嫌の悪い', 'p2.png:二']);

      s.clients.release(2);
      await s.follower.done.timeout(const Duration(seconds: 5));
      expect(diskLines(), <String>['p1.png:機嫌の悪い', 'p2.png:機嫌の悪い']);
    });

    test('一批里盘上已变的那页放弃，其余照写；取消后待写批不落盘', () async {
      await writeDistinctPages();
      final List<MokuroImage> pages = <MokuroImage>[
        localPage('p1.png', '一'),
        localPage('p2.png', '二'),
        localPage('p3.png', '三'),
        localPage('p4.png', '四'),
      ];
      await writeBookJson(pages);
      final s = stepped(
        flushPageCount: 2,
        flushInterval: const Duration(hours: 1),
      );
      final List<MangaOcrPageUpdate> updates = <MangaOcrPageUpdate>[];
      s.follower.updates.listen(updates.add);
      final List<Timer> flushTimers = <Timer>[];
      trackingFlushTimers(
        const Duration(hours: 1),
        flushTimers,
        () =>
            s.follower.onPersisted(mangaJsonPath, MokuroPayload(images: pages)),
      );
      await s.clients.started(1).timeout(const Duration(seconds: 5));
      s.clients.release(1);
      await s.clients.started(2).timeout(const Duration(seconds: 5));
      // 第 1 页在待写期间被别处重新识别过。
      await runExclusiveOnMangaJson<void>(
        mangaJsonPath,
        () => writeMangaJsonAtomically(
          mangaJsonPath,
          MokuroPayload(
            images: <MokuroImage>[
              localPage('p1.png', '新しい'),
              pages[1],
              pages[2],
              pages[3],
            ],
          ),
        ),
      );
      s.clients.release(2);
      await s.clients.started(3).timeout(const Duration(seconds: 5));
      expect(diskLines(), <String>[
        'p1.png:新しい',
        'p2.png:機嫌の悪い',
        'p3.png:三',
        'p4.png:四',
      ]);
      await pumpEventQueue();
      expect(updates.single.pageIndex, 1);

      // 第 3 页改好后进待写批（不够一批），它的定时冲刷已经挂上；此时取消：
      // 定时冲刷被停掉（不留一个到点再去拿写锁的计时器），也不再写盘。
      s.clients.release(3);
      await s.clients.started(4).timeout(const Duration(seconds: 5));
      expect(flushTimers.where((Timer t) => t.isActive), hasLength(1));
      await s.follower.cancel();
      expect(flushTimers.where((Timer t) => t.isActive), isEmpty);
      await s.follower.done.timeout(const Duration(seconds: 5));
      await runExclusiveOnMangaJson<void>(mangaJsonPath, () async {});
      expect(diskLines()[2], 'p3.png:三');
    });

    // 定时冲刷在途（卡在写锁后面）时收尾：收尾必须等它落盘、补发完才关
    // updates / 完成 done——不管收尾自己那一批是空的还是又带了一页。
    for (final bool lastPageRefined in <bool>[false, true]) {
      test('定时冲刷在途时收尾（最后一页${lastPageRefined ? '改好' : '没改成'}）：'
          '等在途那批落盘补发完才结束', () async {
        await writeDistinctPages();
        final List<MokuroImage> pages = <MokuroImage>[
          localPage('p1.png', '一'),
          localPage('p2.png', '二'),
        ];
        await writeBookJson(pages);
        const Duration interval = Duration(milliseconds: 50);
        final s = stepped(
          flushPageCount: 100,
          flushInterval: interval,
          failFrom: lastPageRefined ? null : 2,
        );
        final List<MangaOcrPageUpdate> updates = <MangaOcrPageUpdate>[];
        bool updatesClosed = false;
        s.follower.updates.listen(
          updates.add,
          onDone: () => updatesClosed = true,
        );
        bool done = false;
        unawaited(s.follower.done.then((_) => done = true));

        // 测试先占住写锁：定时冲刷发出后停在锁后面，稳定地「在途」。
        final Completer<void> hold = Completer<void>();
        final Future<void> held = runExclusiveOnMangaJson<void>(
          mangaJsonPath,
          () => hold.future,
        );
        final List<Timer> flushTimers = <Timer>[];
        trackingFlushTimers(
          interval,
          flushTimers,
          () => s.follower.onPersisted(
            mangaJsonPath,
            MokuroPayload(images: pages),
          ),
        );
        await s.clients.started(1).timeout(const Duration(seconds: 5));
        s.clients.release(1);
        await s.clients.started(2).timeout(const Duration(seconds: 5));

        // 最后一页的请求挂着，第 1 页的定时冲刷到点发出（计时器已触发）。
        final Stopwatch waited = Stopwatch()..start();
        while ((flushTimers.isEmpty || flushTimers.first.isActive) &&
            waited.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(flushTimers, hasLength(1));
        expect(flushTimers.single.isActive, isFalse);

        // 放行最后一页 → 收尾。在途那批还没落盘：不能结束、不能关 updates。
        s.clients.release(2);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(done, isFalse, reason: '在途的定时冲刷没落盘，收尾不能先结束');
        expect(updatesClosed, isFalse);
        expect(updates, isEmpty);
        expect(diskLines(), <String>['p1.png:一', 'p2.png:二']);

        hold.complete();
        await held;
        await s.follower.done.timeout(const Duration(seconds: 5));
        await pumpEventQueue();
        expect(diskLines(), <String>[
          'p1.png:機嫌の悪い',
          'p2.png:${lastPageRefined ? '機嫌の悪い' : '二'}',
        ]);
        expect(<int>[
          for (final MangaOcrPageUpdate u in updates) u.pageIndex,
        ], lastPageRefined ? <int>[0, 1] : <int>[0]);
      });
    }
  });
}

/// 逐个放行的客户端：第 n 次请求挂到 `release(n)` 为止。给了 [failFrom] 时，
/// 第 [failFrom] 次请求放行后以限流失败（那页换不成），其后的请求立即失败。
class _SteppedClients {
  _SteppedClients(this.reply, {this.failFrom});

  final String reply;
  final int? failFrom;
  final Map<int, Completer<void>> _started = <int, Completer<void>>{};
  final Map<int, Completer<void>> _gates = <int, Completer<void>>{};
  int calls = 0;

  Completer<void> _of(Map<int, Completer<void>> map, int n) =>
      map.putIfAbsent(n, Completer<void>.new);

  /// 第 [n] 次请求已发出。
  Future<void> started(int n) => _of(_started, n).future;

  void release(int n) {
    final Completer<void> gate = _of(_gates, n);
    if (!gate.isCompleted) gate.complete();
  }

  AiChatClient next() => _SteppedClient(this);
}

class _SteppedClient extends AiChatClient {
  _SteppedClient(this.owner);

  final _SteppedClients owner;
  final Completer<void> _closed = Completer<void>();

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    final int n = owner.calls += 1;
    final int? failFrom = owner.failFrom;
    if (failFrom != null && n > failFrom) {
      throw const AiChatFailure('rate_limited');
    }
    owner._of(owner._started, n).complete();
    await Future.any(<Future<void>>[
      owner._of(owner._gates, n).future,
      _closed.future,
    ]);
    if (_closed.isCompleted) throw const AiChatFailure('network_error');
    if (failFrom != null && n >= failFrom) {
      throw const AiChatFailure('rate_limited');
    }
    return owner.reply;
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// 每次请求一个新客户端；请求挂起直到 [releaseAll]，或客户端被关（=中止）。
class _GatedClients {
  _GatedClients(this.reply);

  final String reply;
  final Completer<void> _gate = Completer<void>();
  final Completer<void> _firstStarted = Completer<void>();
  int calls = 0;
  bool lastClosed = false;

  Future<void> get firstStarted => _firstStarted.future;

  void releaseAll() {
    if (!_gate.isCompleted) _gate.complete();
  }

  AiChatClient next() => _GatedClient(this);
}

class _GatedClient extends AiChatClient {
  _GatedClient(this.owner);

  final _GatedClients owner;
  final Completer<void> _closed = Completer<void>();

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    owner.calls += 1;
    owner.lastClosed = false;
    if (!owner._firstStarted.isCompleted) owner._firstStarted.complete();
    await Future.any(<Future<void>>[owner._gate.future, _closed.future]);
    if (_closed.isCompleted) throw const AiChatFailure('network_error');
    return owner.reply;
  }

  @override
  void close() {
    owner.lastClosed = true;
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// 每次请求都以 [failure] 失败的客户端。
class _FailingClient extends AiChatClient {
  _FailingClient(this.failure);

  final String failure;

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async => throw AiChatFailure(failure);
}
