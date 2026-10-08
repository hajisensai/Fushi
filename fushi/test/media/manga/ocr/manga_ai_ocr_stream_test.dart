import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/ocr/manga_ai_ocr_stream.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
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
