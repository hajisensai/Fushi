import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// BUG-4800：`cancel()` 只是请求——生产的整卷 isolate 要跑完当前页、关掉推理
/// 会话才退出，[result] 到那时才完成。这个 fake 把两步拆开：[cancel] 只记账，
/// [exit] 才让 [result] 以取消收场。
class _LingeringJob implements MangaOcrVolumeJob {
  final Completer<String> _completer = Completer<String>();
  bool cancelRequested = false;

  @override
  Future<String> get result => _completer.future;

  @override
  void cancel() => cancelRequested = true;

  @override
  void focus(int pageIndex) {}

  /// isolate 退出（终局消息到达）。
  void exit() {
    if (!_completer.isCompleted) {
      _completer.completeError(const OcrCancelledException());
    }
  }
}

class _LingeringRunner implements MangaOcrVolumeJobRunner {
  final List<_LingeringJob> jobs = <_LingeringJob>[];

  @override
  MangaOcrVolumeJob start(
    MangaOcrVolumeJobRequest request, {
    required void Function(int pagesDone, int pagesTotal, int pageIndex)
    onProgress,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) {
    final _LingeringJob job = _LingeringJob();
    jobs.add(job);
    return job;
  }
}

/// 真 runner（真起 isolate），只多记一笔「起了几个任务」。
class _CountingIsolateRunner implements MangaOcrVolumeJobRunner {
  int started = 0;

  @override
  MangaOcrVolumeJob start(
    MangaOcrVolumeJobRequest request, {
    required void Function(int pagesDone, int pagesTotal, int pageIndex)
    onProgress,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) {
    started += 1;
    return const IsolateMangaOcrVolumeJobRunner().start(
      request,
      onProgress: onProgress,
      onAcceleration: onAcceleration,
    );
  }
}

/// isolate 在这里同步卡住的时长：模拟原生推理正在跑当前页，取消消息这段时间
/// 进不来。
const Duration _kBusyInIsolate = Duration(milliseconds: 1500);

/// 顶层函数（随 isolate 参数跨 isolate 发送）：在整卷 isolate 里同步卡
/// [_kBusyInIsolate] 再失败——测试里没有 ORT，走到入口的收尾路径即可。
OcrSessionFactory _busyThenThrowingFactoryBuilder() {
  sleep(_kBusyInIsolate);
  throw StateError('no ORT in unit test');
}

/// 顶层函数：在 isolate 自己身上挂退出监听，参数是测试端收通知的 [SendPort]。
void _reportExitBootstrap(Object? arg) {
  Isolate.current.addOnExitListener(arg! as SendPort);
}

Future<void> _settle() async {
  // 链上有真实文件 IO（探逐页缓存、算模型指纹），零延时的事件循环轮转不够。
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 20)) {
      fail('condition not met within 20s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory modelsDir;
  late Directory booksDir;
  late List<MangaOcrModelFile> manifest;

  setUp(() {
    modelsDir = Directory.systemTemp.createTempSync('manga_ocr_exit_models_');
    booksDir = Directory.systemTemp.createTempSync('manga_ocr_exit_books_');
    manifest = <MangaOcrModelFile>[
      for (final MangaOcrModelFile model
          in MangaOcrLocalModel.mangaCtc.manifest)
        MangaOcrModelFile(
          fileName: model.fileName,
          url: 'http://unused.invalid/${model.fileName}',
          expectedBytes: 1,
          role: model.role,
        ),
    ];
    for (final MangaOcrModelFile model in manifest) {
      File(p.join(modelsDir.path, model.fileName)).writeAsBytesSync(<int>[7]);
    }
  });

  tearDown(() {
    for (final Directory dir in <Directory>[modelsDir, booksDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  MangaOcrServiceImpl service(_LingeringRunner runner) => MangaOcrServiceImpl(
    localModel: MangaOcrLocalModel.mangaCtc,
    modelsDirProvider: () async => modelsDir,
    manifest: manifest,
    jobRunner: runner,
    platformSupport: () => true,
  );

  String bookDir(String name) {
    final Directory dir = Directory(p.join(booksDir.path, name))..createSync();
    File(
      p.join(dir.path, 'p1.png'),
    ).writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 80)));
    return dir.path;
  }

  group('BUG-4800：ocrFolder 取消订阅的 Future 等任务真正停下', () {
    test('任务在跑：取消订阅立刻请求中止，但 Future 等到 result 完成', () async {
      final _LingeringRunner runner = _LingeringRunner();
      final StreamSubscription<MangaOcrVolumeEvent> sub = service(
        runner,
      ).ocrFolder(imageDirPath: bookDir('a')).listen((_) {});
      await _waitFor(() => runner.jobs.isNotEmpty);

      bool stopped = false;
      unawaited(sub.cancel().then((_) => stopped = true));
      await _settle();
      expect(runner.jobs.single.cancelRequested, isTrue, reason: '取消请求不等任何东西');
      expect(stopped, isFalse, reason: 'isolate 还在跑当前页：取消订阅的 Future 不能先完成');

      runner.jobs.single.exit();
      await _waitFor(() => stopped);
    });

    test('任务还没起（模型检查中）就取消：没有要等的东西，任务也不会启动', () async {
      final _LingeringRunner runner = _LingeringRunner();
      final StreamSubscription<MangaOcrVolumeEvent> sub = service(
        runner,
      ).ocrFolder(imageDirPath: bookDir('a')).listen((_) {});
      await sub.cancel();
      await _settle();
      expect(runner.jobs, isEmpty);
    });
  });

  // 上面两条用假 runner 把「请求取消」和「退出」拆开；这一条真起 isolate，钉住
  // 生产 runner 的 result 确实等 isolate 收尾——契约的另一半。
  test('BUG-4800 真 isolate：取消订阅的 Future 等整卷 isolate 收尾，不随取消请求完成', () async {
    final OcrSessionFactory Function()? savedBuilder = ocrSessionFactoryBuilder;
    final OcrIsolateBootstrap? savedBootstrap = ocrIsolateBootstrap;
    final Object? savedBootstrapArg = ocrIsolateBootstrapArg;
    final ReceivePort exits = ReceivePort();
    final Completer<void> exited = Completer<void>();
    exits.listen((_) {
      if (!exited.isCompleted) exited.complete();
    });
    addTearDown(() {
      exits.close();
      ocrSessionFactoryBuilder = savedBuilder;
      ocrIsolateBootstrap = savedBootstrap;
      ocrIsolateBootstrapArg = savedBootstrapArg;
    });
    ocrSessionFactoryBuilder = _busyThenThrowingFactoryBuilder;
    ocrIsolateBootstrap = _reportExitBootstrap;
    ocrIsolateBootstrapArg = exits.sendPort;

    final _CountingIsolateRunner runner = _CountingIsolateRunner();
    final MangaOcrServiceImpl real = MangaOcrServiceImpl(
      localModel: MangaOcrLocalModel.mangaCtc,
      modelsDirProvider: () async => modelsDir,
      manifest: manifest,
      jobRunner: runner,
      platformSupport: () => true,
    );
    final StreamSubscription<MangaOcrVolumeEvent> sub = real
        .ocrFolder(imageDirPath: bookDir('a'))
        .listen((_) {}, onError: (Object _) {});
    await _waitFor(() => runner.started == 1);

    bool stopped = false;
    unawaited(sub.cancel().then((_) => stopped = true));
    // isolate 要卡 [_kBusyInIsolate] 才走到收尾；这个点上它一定还活着。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(exited.isCompleted, isFalse, reason: '前提：isolate 还在跑');
    expect(stopped, isFalse, reason: 'isolate 还没收尾：取消订阅的 Future 不能先完成');

    await exited.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('整卷 OCR isolate 没有退出'),
    );
    await _waitFor(() => stopped);
  });

  // 注册表单测用的是假事件流；这里把真链路接起来——注册表 → asyncMap →
  // mangaOcrLocalEvents（async*）→ MangaOcrServiceImpl.ocrFolder——钉住退出信号
  // 一路传得到名额释放那一层，中间任何一层把取消的 Future 丢掉都会变红。
  test('BUG-4800 端到端：暂停后 isolate 没退出前，下一本书拿不到名额', () async {
    final _LingeringRunner runner = _LingeringRunner();
    final MangaOcrWizardEngines engines = MangaOcrWizardEngines(
      service: service(runner),
    );
    MangaOcrJobSpec spec(String dir) => MangaOcrJobSpec(
      engine: MangaOcrEngineId.localOnnx,
      engines: engines,
      imageDirPath: dir,
      lensLanguage: 'ja',
    );
    final String dirA = bookDir('a');
    final String dirB = bookDir('b');
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
      maxConcurrentJobs: () => 1,
    );

    final MangaOcrRunningJob? a = await registry.enqueue(
      job: mangaOcrBackgroundJob(bookKey: 'book-a', spec: spec(dirA)),
      mangaJsonPath: p.join(dirA, 'manga.json'),
    );
    await _waitFor(() => runner.jobs.length == 1);
    unawaited(
      registry.enqueue(
        job: mangaOcrBackgroundJob(bookKey: 'book-b', spec: spec(dirB)),
        mangaJsonPath: p.join(dirB, 'manga.json'),
      ),
    );

    expect(await registry.pause('book-a', dirA), isTrue, reason: '暂停立即返回');
    // 没有任何进度事件帮忙：取消请求必须当场传到 isolate，不能等它跑完当前页、
    // 报了进度之后才传（那样它还要再多跑一页）。
    await _waitFor(() => runner.jobs.first.cancelRequested);
    await _settle();
    expect(a!.isEnded, isTrue);
    expect(a.isStopped, isFalse);
    expect(
      runner.jobs,
      hasLength(1),
      reason: '旧 isolate 没退出：手机「只跑 1 卷」不能在这段时间里变成 2 卷',
    );
    expect(registry.running('book-b'), isNull);

    runner.jobs.first.exit();
    await _waitFor(() => runner.jobs.length == 2);
    expect(a.isStopped, isTrue);
    expect(registry.running('book-b'), isNotNull);

    await registry.cancelAll();
    runner.jobs.last.exit();
    await _settle();
  });
}
