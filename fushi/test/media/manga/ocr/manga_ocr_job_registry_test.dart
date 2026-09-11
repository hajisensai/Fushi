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
      final StreamSubscription<MangaOcrBackgroundEvent> pageSub =
          running.events.listen((MangaOcrBackgroundEvent e) {
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
      source.controller.add(MangaOcrBackgroundEvent.finished(
        pagesTotal: 3,
        resultPath: resultPath,
        external: false,
      ));
      await source.controller.close();
      await done;

      expect(File(mangaJsonPath).existsSync(), isTrue, reason: '页面不在也要落盘');
      final MokuroPayload written =
          parseMangaJson(File(mangaJsonPath).readAsStringSync());
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
      source.controller.add(MangaOcrBackgroundEvent.finished(
        pagesTotal: 2,
        resultPath: resultPath,
        external: false,
      ));
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
      expect(second.controller.hasListener, isFalse,
          reason: '第二份根本不该被订阅（订阅即启动）');
      await registry.cancelAll();
      expect(first.cancelled, isTrue);
    });
  });
}
