import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 可观察取消的底层事件流：`cancelled` 为 true 才代表执行器真的收到了中止。
class _FakeSource {
  _FakeSource() {
    controller = StreamController<MangaOcrBackgroundEvent>(
      onCancel: () => cancelled = true,
    );
  }

  late final StreamController<MangaOcrBackgroundEvent> controller;
  bool cancelled = false;

  MangaOcrBackgroundJob job(String bookKey, String dir) =>
      MangaOcrBackgroundJob(
        bookKey: bookKey,
        managedDirectory: dir,
        engine: MangaOcrEngineId.localOnnx,
        events: controller.stream,
      );
}

class _FakeSession implements MangaReaderSession {
  bool closed = false;

  @override
  int get pageCount => 0;

  @override
  Future<MangaPageBytes> page(int index) => throw UnimplementedError();

  @override
  Future<File?> localFile(int index) async => null;

  @override
  String cacheIdentity(int index) => 'p$index';

  @override
  Future<void> close() async {
    closed = true;
  }
}

String _resultJson(int pages) => jsonEncode(<String, Object?>{
  'pages': <Map<String, Object?>>[
    for (int i = 0; i < pages; i++)
      <String, Object?>{
        'url': 'images/p$i.jpg',
        'width': 100,
        'height': 150,
        'blocks': <Object?>[],
      },
  ],
});

MangaOcrBackgroundEvent _progress(int done, int total) =>
    MangaOcrBackgroundEvent.progress(pagesDone: done, pagesTotal: total);

void main() {
  late Directory tmp;
  late String mangaJsonPath;
  late String resultPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ocr_job_registry_');
    mangaJsonPath = p.join(tmp.path, 'manga.json');
    resultPath = p.join(tmp.path, 'manga_ocr_out', 'manga.json');
    File(resultPath).createSync(recursive: true);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('MangaOcrJobRegistry（BUG-2449：任务所有权在 app 级，不在页面 State）', () {
    test('观察者取消订阅不会中止底层任务；事件继续到达后来的观察者', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource source = _FakeSource();
      final MangaOcrRunningJob running = registry.start(
        job: source.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
      );
      final List<int> seenByPage = <int>[];
      final StreamSubscription<MangaOcrBackgroundEvent> pageSub = running.events
          .listen((MangaOcrBackgroundEvent e) {
            seenByPage.add(e.pagesDone);
          });
      source.controller.add(_progress(1, 5));
      await Future<void>.delayed(Duration.zero);
      expect(seenByPage, <int>[1]);

      // 模拟阅读页 dispose：只取消观察。
      await pageSub.cancel();
      source.controller.add(_progress(2, 5));
      await Future<void>.delayed(Duration.zero);

      expect(source.cancelled, isFalse, reason: '退出页面不得杀任务');
      expect(registry.running('book'), same(running));
      expect(running.lastEvent?.pagesDone, 2, reason: '快照给晚到的观察者补 HUD');

      // 重进同书：拿到同一个任务，接着收后续事件。
      final List<int> seenAgain = <int>[];
      registry.running('book')!.events.listen((MangaOcrBackgroundEvent e) {
        seenAgain.add(e.pagesDone);
      });
      source.controller.add(_progress(3, 5));
      await Future<void>.delayed(Duration.zero);
      expect(seenAgain, <int>[3]);
      await registry.cancelAll();
    });

    test('HUD 取消才真停：底层流收到 cancel、会话关闭、注册表移除', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource source = _FakeSource();
      final _FakeSession session = _FakeSession();
      final MangaOcrRunningJob running = registry.start(
        job: source.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
        sessions: <MangaReaderSession>[session],
      );
      expect(running.ownsSession(session), isTrue);
      expect(running.ownsSession(_FakeSession()), isFalse);

      await registry.cancel('book');

      expect(source.cancelled, isTrue);
      expect(session.closed, isTrue);
      expect(running.isCancelled, isTrue);
      expect(running.isEnded, isTrue);
      expect(registry.running('book'), isNull);
      await registry.cancel('book'); // 幂等
    });

    test('零观察者时完成：产物仍落进书根 manga.json，result 可供重进的页面读', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource source = _FakeSource();
      final _FakeSession session = _FakeSession();
      final MangaOcrRunningJob running = registry.start(
        job: source.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
        sessions: <MangaReaderSession>[session],
      );
      File(resultPath).writeAsStringSync(_resultJson(3));
      final Future<void> done = running.events.drain<void>();
      source.controller.add(
        MangaOcrBackgroundEvent.finished(
          pagesTotal: 3,
          resultPath: resultPath,
          external: false,
        ),
      );
      await source.controller.close();
      await done;

      expect(File(mangaJsonPath).existsSync(), isTrue, reason: '页面不在也要落盘');
      final MokuroPayload written = parseMangaJson(
        File(mangaJsonPath).readAsStringSync(),
      );
      expect(written.images, hasLength(3));
      expect(running.result?.images, hasLength(3));
      expect(running.isEnded, isTrue);
      expect(session.closed, isTrue, reason: '任务结束由注册表关会话');
      expect(registry.running('book'), isNull);
    });

    test('finished 在落盘之后才转发：观察者收到时文件已在盘上', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource source = _FakeSource();
      final MangaOcrRunningJob running = registry.start(
        job: source.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
      );
      File(resultPath).writeAsStringSync(_resultJson(2));
      bool existedOnFinish = false;
      final Completer<void> got = Completer<void>();
      running.events.listen((MangaOcrBackgroundEvent e) {
        if (e.finished) {
          existedOnFinish = File(mangaJsonPath).existsSync();
          got.complete();
        }
      });
      source.controller.add(
        MangaOcrBackgroundEvent.finished(
          pagesTotal: 2,
          resultPath: resultPath,
          external: false,
        ),
      );
      await got.future;
      expect(existedOnFinish, isTrue);
      await source.controller.close();
    });

    test('底层报错：观察者收到 error，任务从注册表移除、会话关闭', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource source = _FakeSource();
      final _FakeSession session = _FakeSession();
      final MangaOcrRunningJob running = registry.start(
        job: source.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
        sessions: <MangaReaderSession>[session],
      );
      Object? seen;
      final Completer<void> got = Completer<void>();
      running.events.listen(
        (_) {},
        onError: (Object e) {
          seen = e;
          got.complete();
        },
      );
      source.controller.addError(StateError('engine died'));
      await got.future;
      await Future<void>.delayed(Duration.zero);
      expect(seen, isA<StateError>());
      expect(running.error, isA<StateError>());
      expect(registry.running('book'), isNull);
      expect(session.closed, isTrue);
    });

    test('同书重复启动返回已在跑的任务，不并发跑第二份', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource first = _FakeSource();
      final _FakeSource second = _FakeSource();
      final MangaOcrRunningJob a = registry.start(
        job: first.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
      );
      final MangaOcrRunningJob b = registry.start(
        job: second.job('book', tmp.path),
        mangaJsonPath: mangaJsonPath,
      );
      expect(b, same(a));
      expect(
        second.controller.hasListener,
        isFalse,
        reason: '第二份根本不该被订阅（订阅即启动）',
      );
      await registry.cancelAll();
      expect(first.cancelled, isTrue);
    });

    test(
      'changes / queuedDirectories：入队、轮到、结束都发信号，排队目录按序可查（BUG-2481）',
      () async {
        final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
        int changes = 0;
        final StreamSubscription<void> watch = registry.changes.listen(
          (_) => changes++,
        );
        final _FakeSource first = _FakeSource();
        final _FakeSource second = _FakeSource();
        final String dirA = p.join(tmp.path, 'a');
        final String dirB = p.join(tmp.path, 'b');

        final Future<MangaOcrRunningJob?> startedA = registry.enqueue(
          job: first.job('book', dirA),
          mangaJsonPath: mangaJsonPath,
        );
        final Future<MangaOcrRunningJob?> startedB = registry.enqueue(
          job: second.job('book', dirB),
          mangaJsonPath: mangaJsonPath,
        );
        await startedA;
        await Future<void>.delayed(Duration.zero);
        // A 在跑、B 排队：排队目录只有 B。
        expect(registry.running('book')!.job.managedDirectory, dirA);
        expect(registry.queuedDirectories('book'), <String>[dirB]);
        expect(changes, greaterThan(0));
        final int beforeEnd = changes;

        // A 结束 → B 轮到：排队清空、running 换成 B、又有信号。
        await first.controller.close();
        await startedB;
        await Future<void>.delayed(Duration.zero);
        expect(registry.running('book')!.job.managedDirectory, dirB);
        expect(registry.queuedDirectories('book'), isEmpty);
        expect(changes, greaterThan(beforeEnd));

        await registry.cancelAll();
        await watch.cancel();
      },
    );

    test('cancel(bookKey) 连排队的一起放弃：A 停后 B 不启动、enqueue 以 null 完成', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource first = _FakeSource();
      final _FakeSource second = _FakeSource();
      final String dirA = p.join(tmp.path, 'a');
      final String dirB = p.join(tmp.path, 'b');
      final Future<MangaOcrRunningJob?> startedA = registry.enqueue(
        job: first.job('book', dirA),
        mangaJsonPath: mangaJsonPath,
      );
      final Future<MangaOcrRunningJob?> startedB = registry.enqueue(
        job: second.job('book', dirB),
        mangaJsonPath: mangaJsonPath,
      );
      expect(await startedA, isNotNull);
      expect(registry.queuedDirectories('book'), <String>[dirB]);

      await registry.cancel('book');
      expect(first.cancelled, isTrue);
      expect(registry.queuedDirectories('book'), isEmpty);
      expect(await startedB, isNull, reason: '排队者被放弃，不该启动');
      await Future<void>.delayed(Duration.zero);
      expect(registry.running('book'), isNull);
      expect(second.controller.hasListener, isFalse, reason: '订阅即启动：B 根本不该被订阅');
      // 另一本书不受影响；同书再 enqueue 仍能正常启动。
      final _FakeSource third = _FakeSource();
      final MangaOcrRunningJob? c = await registry.enqueue(
        job: third.job('book', dirA),
        mangaJsonPath: mangaJsonPath,
      );
      expect(c, isNotNull);
      await registry.cancelAll();
    });

    test('跨书全局名额：上限 1 时第二本书等第一本结束才启动，等名额期间算排队中', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _FakeSource first = _FakeSource();
      final _FakeSource second = _FakeSource();
      final String dirA = p.join(tmp.path, 'a');
      final String dirB = p.join(tmp.path, 'b');
      final Future<MangaOcrRunningJob?> startedA = registry.enqueue(
        job: first.job('book-a', dirA),
        mangaJsonPath: mangaJsonPath,
      );
      final Future<MangaOcrRunningJob?> startedB = registry.enqueue(
        job: second.job('book-b', dirB),
        mangaJsonPath: mangaJsonPath,
      );
      expect(await startedA, isNotNull);
      await Future<void>.delayed(Duration.zero);
      expect(registry.running('book-b'), isNull, reason: '名额被 A 占着');
      expect(second.controller.hasListener, isFalse, reason: '订阅即启动');
      expect(registry.queuedDirectories('book-b'), <String>[dirB]);

      await first.controller.close();
      expect(await startedB, isNotNull);
      expect(registry.running('book-b')!.job.managedDirectory, dirB);
      await registry.cancelAll();
    });

    test('等名额期间被 cancel 的书不启动，名额顺延给下一本', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _FakeSource first = _FakeSource();
      final _FakeSource second = _FakeSource();
      final _FakeSource third = _FakeSource();
      final Future<MangaOcrRunningJob?> startedA = registry.enqueue(
        job: first.job('book-a', p.join(tmp.path, 'a')),
        mangaJsonPath: mangaJsonPath,
      );
      final Future<MangaOcrRunningJob?> startedB = registry.enqueue(
        job: second.job('book-b', p.join(tmp.path, 'b')),
        mangaJsonPath: mangaJsonPath,
      );
      final Future<MangaOcrRunningJob?> startedC = registry.enqueue(
        job: third.job('book-c', p.join(tmp.path, 'c')),
        mangaJsonPath: mangaJsonPath,
      );
      expect(await startedA, isNotNull);
      await registry.cancel('book-b');
      await first.controller.close();
      expect(await startedB, isNull);
      expect(second.controller.hasListener, isFalse);
      expect(await startedC, isNotNull, reason: 'B 放弃后名额必须顺延，不能卡死');
      await registry.cancelAll();
    });

    test('并发从 1 调到 3：原任务未结束也立即启动两个排队任务', () async {
      int limit = 1;
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => limit,
      );
      final List<_FakeSource> sources = List<_FakeSource>.generate(
        4,
        (int _) => _FakeSource(),
      );
      final List<Future<MangaOcrRunningJob?>> started =
          <Future<MangaOcrRunningJob?>>[
            for (int i = 0; i < sources.length; i++)
              registry.enqueue(
                job: sources[i].job('book-$i', p.join(tmp.path, '$i')),
                mangaJsonPath: mangaJsonPath,
              ),
          ];
      final MangaOcrRunningJob first = (await started[0])!;
      await Future<void>.delayed(Duration.zero);
      expect(
        sources.skip(1).every((_FakeSource s) => !s.controller.hasListener),
        isTrue,
      );

      limit = 3;
      registry.refreshConcurrencyLimit();
      expect(await started[1], isNotNull);
      expect(await started[2], isNotNull);
      expect(first.isEnded, isFalse, reason: '扩容不得靠先结束原任务来放行');
      expect(sources[0].cancelled, isFalse);
      expect(registry.all, hasLength(3));
      expect(sources[3].controller.hasListener, isFalse);

      await sources[0].controller.close();
      expect(await started[3], isNotNull);
      for (final _FakeSource source in sources.skip(1)) {
        await source.controller.close();
      }
      await registry.cancelAll();
    });

    test('并发从 3 调到 1：保留已运行任务，归还足够名额后才启动后续任务', () async {
      int limit = 3;
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => limit,
      );
      final List<_FakeSource> sources = List<_FakeSource>.generate(
        5,
        (int _) => _FakeSource(),
      );
      final List<Future<MangaOcrRunningJob?>> started =
          <Future<MangaOcrRunningJob?>>[
            for (int i = 0; i < sources.length; i++)
              registry.enqueue(
                job: sources[i].job('book-$i', p.join(tmp.path, '$i')),
                mangaJsonPath: mangaJsonPath,
              ),
          ];
      final List<MangaOcrRunningJob> running = <MangaOcrRunningJob>[
        for (int i = 0; i < 3; i++) (await started[i])!,
      ];

      limit = 1;
      registry.refreshConcurrencyLimit();
      expect(running.every((MangaOcrRunningJob job) => !job.isEnded), isTrue);
      expect(sources.take(3).every((_FakeSource s) => !s.cancelled), isTrue);
      expect(registry.all, hasLength(3));

      for (int i = 0; i < 2; i++) {
        await sources[i].controller.close();
        await running[i].whenEnded;
        await Future<void>.delayed(Duration.zero);
        expect(
          sources[3].controller.hasListener,
          isFalse,
          reason: '缩容后仍有运行任务时，不得用旧上限启动第四本书',
        );
        expect(sources[4].controller.hasListener, isFalse);
      }
      await sources[2].controller.close();
      expect(await started[3], isNotNull);
      expect(
        sources[4].controller.hasListener,
        isFalse,
        reason: '归还全部旧名额后也只应按新上限启动一本',
      );
      await sources[3].controller.close();
      expect(await started[4], isNotNull);
      await sources[4].controller.close();
      await registry.cancelAll();
    });

    test('不给上限（默认）：两本书同时跑', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _FakeSource first = _FakeSource();
      final _FakeSource second = _FakeSource();
      expect(
        await registry.enqueue(
          job: first.job('book-a', p.join(tmp.path, 'a')),
          mangaJsonPath: mangaJsonPath,
        ),
        isNotNull,
      );
      expect(
        await registry.enqueue(
          job: second.job('book-b', p.join(tmp.path, 'b')),
          mangaJsonPath: mangaJsonPath,
        ),
        isNotNull,
      );
      await registry.cancelAll();
    });
  });

  group('resolveMangaOcrJobConcurrency（按设备自适应）', () {
    test('手动并发 1～4 覆盖桌面自动值，0 恢复按核数自动选择', () {
      for (int requested = 1; requested <= 4; requested++) {
        expect(
          resolveMangaOcrJobConcurrency(
            isMobile: false,
            lowMemoryMode: false,
            processors: 2,
            requestedTasks: requested,
          ),
          requested,
        );
      }
      expect(
        resolveMangaOcrJobConcurrency(
          isMobile: false,
          lowMemoryMode: false,
          processors: 16,
          requestedTasks: 0,
        ),
        2,
      );
    });

    test('显式选择 4 也不能越过手机和低内存模式的单任务限制', () {
      for (final (bool mobile, bool lowMemory) in <(bool, bool)>[
        (true, false),
        (false, true),
        (true, true),
      ]) {
        expect(
          resolveMangaOcrJobConcurrency(
            isMobile: mobile,
            lowMemoryMode: lowMemory,
            processors: 32,
            requestedTasks: 4,
          ),
          1,
        );
      }
    });

    test('手机与低内存模式只跑 1 卷', () {
      expect(
        resolveMangaOcrJobConcurrency(
          isMobile: true,
          lowMemoryMode: false,
          processors: 8,
        ),
        1,
      );
      expect(
        resolveMangaOcrJobConcurrency(
          isMobile: false,
          lowMemoryMode: true,
          processors: 16,
        ),
        1,
      );
    });

    test('桌面按核数给 1～2 卷', () {
      int desktop(int processors) => resolveMangaOcrJobConcurrency(
        isMobile: false,
        lowMemoryMode: false,
        processors: processors,
      );
      expect(desktop(2), 1);
      expect(desktop(4), 1);
      expect(desktop(8), 2);
      expect(desktop(32), 2);
    });
  });
}
