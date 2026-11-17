import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';

/// BUG-4800：取消 / 暂停只是「请求停」，本地模型要跑完当前页、关掉推理会话、
/// isolate 退出之后那套模型才离开内存。注册表的全局名额与同书队列必须等到
/// 那一刻，而不是用户点下去的那一刻。
///
/// 这里的底层流模拟「慢慢才停下」的执行器：取消订阅的 Future 要等 [exit] 才
/// 完成（`MangaOcrService.ocrFolder` 的契约）。
class _SlowStopSource {
  _SlowStopSource({this.stopError}) {
    controller = StreamController<MangaOcrBackgroundEvent>(
      onCancel: () {
        cancelRequested = true;
        return _exited.future;
      },
    );
  }

  /// 执行器收尾时抛的错（null = 正常停下）。
  final Object? stopError;

  late final StreamController<MangaOcrBackgroundEvent> controller;
  final Completer<void> _exited = Completer<void>();
  bool cancelRequested = false;

  /// isolate 退出。
  void exit() {
    final Object? error = stopError;
    if (error == null) {
      _exited.complete();
    } else {
      _exited.completeError(error);
    }
  }

  MangaOcrBackgroundJob job(
    String bookKey,
    String dir, {
    MangaOcrBackgroundJob Function()? resume,
  }) => MangaOcrBackgroundJob(
    bookKey: bookKey,
    managedDirectory: dir,
    engine: MangaOcrEngineId.localOnnx,
    events: controller.stream,
    resume: resume,
  );
}

Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory tmp;
  late String mangaJsonPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ocr_job_registry_stop_');
    mangaJsonPath = p.join(tmp.path, 'manga.json');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('BUG-4800：名额与同书队列等执行器真正停下', () {
    test('取消本书：cancel 立即返回，但名额等 isolate 退出才让给下一本', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _SlowStopSource first = _SlowStopSource();
      final _SlowStopSource second = _SlowStopSource();
      final MangaOcrRunningJob? a = await registry.enqueue(
        job: first.job('book-a', p.join(tmp.path, 'a')),
        mangaJsonPath: mangaJsonPath,
      );
      MangaOcrRunningJob? b;
      unawaited(
        registry
            .enqueue(
              job: second.job('book-b', p.join(tmp.path, 'b')),
              mangaJsonPath: mangaJsonPath,
            )
            .then((MangaOcrRunningJob? started) => b = started),
      );
      await _settle();
      expect(b, isNull, reason: '上限 1：B 在等名额');

      // 用户侧的取消不等 isolate 退出：删书 / 切 Profile / 退出 app 都 await 它。
      await registry.cancel('book-a');
      expect(first.cancelRequested, isTrue);
      expect(a!.isEnded, isTrue, reason: '界面上任务已经没了');
      expect(a.isStopped, isFalse, reason: '执行器还在跑当前页');
      expect(registry.running('book-a'), isNull);

      await _settle();
      expect(b, isNull, reason: '旧 isolate 还没退出：名额不能放，否则两套模型同时在内存');
      expect(second.controller.hasListener, isFalse);

      first.exit();
      await _settle();
      expect(a.isStopped, isTrue);
      expect(b, isNotNull, reason: 'isolate 退出后名额才让给 B');
      expect(second.controller.hasListener, isTrue);

      second.exit();
      await registry.cancelAll();
    });

    test('暂停后立刻继续：重建的任务等旧 isolate 退出才开跑', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _SlowStopSource first = _SlowStopSource();
      final _SlowStopSource rebuilt = _SlowStopSource();
      final String dir = p.join(tmp.path, 'a');
      await registry.enqueue(
        job: first.job('book-a', dir, resume: () => rebuilt.job('book-a', dir)),
        mangaJsonPath: mangaJsonPath,
      );

      expect(await registry.pause('book-a', dir), isTrue, reason: '暂停立即返回');
      expect(registry.resume('book-a', dir), isTrue);
      await _settle();
      expect(
        rebuilt.controller.hasListener,
        isFalse,
        reason: '旧 isolate 正在收尾的那一页，正是新任务按缓存跳过后要补的第一页',
      );
      expect(registry.queuedDirectories('book-a'), <String>[
        dir,
      ], reason: '等旧任务停下期间算排队中');

      first.exit();
      await _settle();
      expect(rebuilt.controller.hasListener, isTrue);
      expect(registry.running('book-a')?.job.managedDirectory, dir);

      rebuilt.exit();
      await registry.cancelAll();
    });

    test('不占名额直接 start 的任务被暂停后：同书重新排上的也等它退出', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
      final _SlowStopSource first = _SlowStopSource();
      final _SlowStopSource rebuilt = _SlowStopSource();
      final String dir = p.join(tmp.path, 'a');
      registry.start(
        job: first.job('book-a', dir, resume: () => rebuilt.job('book-a', dir)),
        mangaJsonPath: mangaJsonPath,
      );

      expect(await registry.pause('book-a', dir), isTrue);
      expect(registry.resume('book-a', dir), isTrue);
      await _settle();
      expect(rebuilt.controller.hasListener, isFalse);

      first.exit();
      await _settle();
      expect(rebuilt.controller.hasListener, isTrue);

      rebuilt.exit();
      await registry.cancelAll();
    });

    test('cancelAll 不等 isolate 退出；退出前同书新任务不启动', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _SlowStopSource first = _SlowStopSource();
      final _SlowStopSource next = _SlowStopSource();
      final String dir = p.join(tmp.path, 'a');
      await registry.enqueue(
        job: first.job('book-a', dir),
        mangaJsonPath: mangaJsonPath,
      );

      // 切 Profile / 退出 app：不能被一个还在跑当前页的 isolate 挂住。
      await registry.cancelAll();
      expect(first.cancelRequested, isTrue);

      MangaOcrRunningJob? started;
      unawaited(
        registry
            .enqueue(job: next.job('book-a', dir), mangaJsonPath: mangaJsonPath)
            .then((MangaOcrRunningJob? job) => started = job),
      );
      await _settle();
      expect(started, isNull);

      first.exit();
      await _settle();
      expect(started, isNotNull);

      next.exit();
      await registry.cancelAll();
    });

    test('自己报错收尾的任务：结束即停下，名额当场让出', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _SlowStopSource first = _SlowStopSource();
      final _SlowStopSource second = _SlowStopSource();
      final MangaOcrRunningJob? a = await registry.enqueue(
        job: first.job('book-a', p.join(tmp.path, 'a')),
        mangaJsonPath: mangaJsonPath,
      );
      final Future<MangaOcrRunningJob?> startedB = registry.enqueue(
        job: second.job('book-b', p.join(tmp.path, 'b')),
        mangaJsonPath: mangaJsonPath,
      );

      // 底层流自己报错收尾：订阅是 cancelOnError，流会先等执行器停下（取消的
      // Future）再把错误交出来，所以「结束」与「停下」是同一刻。
      first.controller.addError(StateError('boom'));
      await _settle();
      expect(a!.isEnded, isFalse, reason: '执行器还没停，错误还没交到注册表');
      first.exit();
      await _settle();
      expect(a.isEnded, isTrue);
      expect(a.isStopped, isTrue);
      expect(await startedB, isNotNull);

      second.exit();
      await registry.cancelAll();
    });

    test('执行器收尾抛错：名额照样还回去，不卡死后面的任务', () async {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () => 1,
      );
      final _SlowStopSource first = _SlowStopSource(
        stopError: StateError('cleanup failed'),
      );
      final _SlowStopSource second = _SlowStopSource();
      await registry.enqueue(
        job: first.job('book-a', p.join(tmp.path, 'a')),
        mangaJsonPath: mangaJsonPath,
      );
      final Future<MangaOcrRunningJob?> startedB = registry.enqueue(
        job: second.job('book-b', p.join(tmp.path, 'b')),
        mangaJsonPath: mangaJsonPath,
      );

      await registry.cancel('book-a');
      first.exit();
      expect(await startedB, isNotNull);

      second.exit();
      await registry.cancelAll();
    });
  });
}
