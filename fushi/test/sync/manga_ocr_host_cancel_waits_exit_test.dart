/// BUG-4800 在互联主机一侧的落点：[MangaOcrService.ocrFolder] 取消订阅的 Future
/// 现在等到执行体真正停下（本地模型 = 整卷 isolate 已退出）才完成，
/// [MangaOcrHostJobManager.cancelAndCleanup] await 的就是它。
///
/// 主机的串行队列与全局名额是同一个问题：旧 isolate 还占着整套模型时就放行下一
/// 个任务，主机上就是两套模型同时在内存；页图也不能在旧 isolate 还在读的时候删。
///
/// [MangaOcrHostJobManager.disposeAll] 相反，不能等：`FushiSyncServer.stop()`
/// 顺序 await 它，原生推理卡住时取消的 Future 永远不完成。它只发取消、清表就
/// 返回，各任务的收尾仍排在自己的执行体停下之后。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 每次 [ocrFolder] 起一个挂着不结束的任务；取消订阅的 Future 等 [exit] 才完成
/// （生产实现里是整卷 isolate 退出）。
class _LingeringOcrService implements MangaOcrService {
  final List<Completer<void>> exits = <Completer<void>>[];
  final List<String> startedDirs = <String>[];
  int cancelRequests = 0;

  /// 非 null 时 [modelStatus] 等它完成才返回（模拟查模型状态要花时间）。
  Completer<void>? modelStatusGate;
  int modelStatusCalls = 0;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async {
    modelStatusCalls += 1;
    await modelStatusGate?.future;
    return const MangaOcrModelStatus(
      detectorReady: true,
      recognizerReady: true,
      diskBytes: 1,
      totalBytes: 1,
    );
  }

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
  }) {
    final Completer<void> exit = Completer<void>();
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    controller.onListen = () {
      exits.add(exit);
      startedDirs.add(imageDirPath);
    };
    controller.onCancel = () {
      cancelRequests += 1;
      return exit.future;
    };
    return controller.stream;
  }
}

Future<void> _settle() async {
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
  late Directory tmpRoot;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('hbk_manga_ocr_exit');
  });

  tearDown(() {
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  test('cancelAndCleanup 等执行体真正停下：在那之前不删页图、不放行排在后面的任务', () async {
    final _LingeringOcrService service = _LingeringOcrService();
    final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
    );

    final MangaOcrHostJob a = manager.createJob(volumeTitle: '卷一');
    expect(
      await manager.uploadPage(a, name: 'p001.jpg', bytes: <int>[1]),
      isNull,
    );
    final MangaOcrHostJob b = manager.createJob(volumeTitle: '卷二');
    expect(
      await manager.uploadPage(b, name: 'p001.jpg', bytes: <int>[2]),
      isNull,
    );
    expect(await manager.start(a), isNull);
    expect(await manager.start(b), isNull);
    await _waitFor(() => service.startedDirs.length == 1);
    expect(service.startedDirs.single, a.dir.path, reason: '串行：B 排在 A 后面');

    bool cleaned = false;
    unawaited(manager.cancelAndCleanup(a).then((_) => cleaned = true));
    await _waitFor(() => service.cancelRequests == 1);
    await _settle();
    expect(cleaned, isFalse, reason: '旧执行体还在跑当前页');
    expect(
      File(p.join(a.dir.path, 'p001.jpg')).existsSync(),
      isTrue,
      reason: '它还在读页图，不能先删',
    );
    expect(service.startedDirs, hasLength(1), reason: '旧执行体的模型还在内存里：下一个任务不能先起');

    service.exits.first.complete();
    await _waitFor(() => cleaned);
    expect(File(p.join(a.dir.path, 'p001.jpg')).existsSync(), isFalse);
    await _waitFor(() => service.startedDirs.length == 2);
    expect(service.startedDirs.last, b.dir.path);

    // 收尾：B 的执行体也「退出」，不留挂着的取消。
    service.exits.last.complete();
    await manager.cancelAndCleanup(b);
  });

  /// 建任务、传一页、start。
  Future<MangaOcrHostJob> startedJob(
    MangaOcrHostJobManager manager,
    String title,
  ) async {
    final MangaOcrHostJob job = manager.createJob(volumeTitle: title);
    expect(
      await manager.uploadPage(job, name: 'p001.jpg', bytes: <int>[1]),
      isNull,
    );
    expect(await manager.start(job), isNull);
    return job;
  }

  test('start 正在等模型状态时任务被取消：回来不再起跑', () async {
    final _LingeringOcrService service = _LingeringOcrService()
      ..modelStatusGate = Completer<void>();
    final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
    );
    final MangaOcrHostJob job = manager.createJob(volumeTitle: '卷一');
    expect(
      await manager.uploadPage(job, name: 'p001.jpg', bytes: <int>[1]),
      isNull,
    );
    final Future<(int, String)?> starting = manager.start(job);
    await _waitFor(() => service.modelStatusCalls == 1);

    await manager.cancelAndCleanup(job);
    service.modelStatusGate!.complete();
    expect(await starting, (409, 'bad_state'));
    await _settle();
    expect(job.state, MangaOcrHostJobState.cancelled);
    expect(service.startedDirs, isEmpty);
  });

  test('两个 start 同时在等模型状态：只起一个执行体', () async {
    final _LingeringOcrService service = _LingeringOcrService()
      ..modelStatusGate = Completer<void>();
    final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
    );
    final MangaOcrHostJob job = manager.createJob(volumeTitle: '卷一');
    expect(
      await manager.uploadPage(job, name: 'p001.jpg', bytes: <int>[1]),
      isNull,
    );
    final Future<(int, String)?> first = manager.start(job);
    final Future<(int, String)?> second = manager.start(job);
    await _waitFor(() => service.modelStatusCalls == 2);
    service.modelStatusGate!.complete();
    expect(await first, isNull);
    expect(await second, isNull, reason: '已受理的任务再 start 是幂等的');
    await _waitFor(() => service.startedDirs.length == 1);
    await _settle();
    expect(service.startedDirs, hasLength(1));

    service.exits.single.complete();
    await manager.cancelAndCleanup(job);
  });

  group('disposeAll', () {
    test('执行体没停就返回；排队中的任务不再启动；完成信号等执行体停下才补', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      final MangaOcrHostJob a = await startedJob(manager, '卷一');
      final MangaOcrHostJob b = await startedJob(manager, '卷二');
      await _waitFor(() => service.startedDirs.length == 1);

      // 执行体一直不退出（原生推理卡住）：disposeAll 也得返回。
      await manager.disposeAll().timeout(const Duration(seconds: 5));
      expect(service.cancelRequests, 1, reason: '取消已经发给在跑的执行体');
      expect(manager.jobCount, 0);
      expect(a.state, MangaOcrHostJobState.cancelled);
      expect(b.state, MangaOcrHostJobState.cancelled);

      bool allStopped = false;
      unawaited(manager.whenExecutorsStopped.then((_) => allStopped = true));

      // 管理器仍被引用时再来一个任务：旧执行体还占着模型，它不能先起。
      final MangaOcrHostJob c = await startedJob(manager, '卷三');
      await _settle();
      expect(service.startedDirs, hasLength(1), reason: '旧执行体停下之前队列不放行');
      expect(allStopped, isFalse);

      service.exits.first.complete();
      await _waitFor(() => service.startedDirs.length == 2);
      expect(service.startedDirs.last, c.dir.path, reason: '停机时还在排队的 B 不再启动');
      expect(allStopped, isTrue);

      service.exits.last.complete();
      await manager.cancelAndCleanup(c);
    });

    test('等执行体停下的那段时间里别的路径增删任务：不抛并发修改', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      await startedJob(manager, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);
      // 表里排在在跑任务后面的两个：遍历还要往下走。
      final MangaOcrHostJob pending = manager.createJob(volumeTitle: '卷二');
      manager.createJob(volumeTitle: '卷三');

      final Future<void> disposed = manager.disposeAll();
      // 停机途中：新建一个任务、删掉一个旧任务。
      final MangaOcrHostJob added = manager.createJob(volumeTitle: '卷四');
      await manager.cancelAndCleanup(pending);
      service.exits.first.complete();
      await disposed.timeout(const Duration(seconds: 5));
      await manager.whenExecutorsStopped;

      expect(manager.job(added.id), same(added), reason: '停机之后建的任务不被清表带走');
      expect(manager.jobCount, 1);
    });

    test('途中的 cancelAndCleanup：disposeAll 先返回；执行体停下后不删已出表任务的页图', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      final MangaOcrHostJob a = await startedJob(manager, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);
      final File pageImage = File(p.join(a.dir.path, 'p001.jpg'));

      bool cleaned = false;
      unawaited(manager.cancelAndCleanup(a).then((_) => cleaned = true));
      await manager.disposeAll().timeout(const Duration(seconds: 5));
      await _settle();
      expect(cleaned, isFalse);
      expect(pageImage.existsSync(), isTrue, reason: '执行体还在读页图，不能先删');
      expect(a.dir.existsSync(), isTrue, reason: '停机不删任务目录');

      service.exits.first.complete();
      await _waitFor(() => cleaned);
      await manager.whenExecutorsStopped;
      expect(
        pageImage.existsSync(),
        isTrue,
        reason: '任务已被停机摘出表：目录归谁本管理器不知道了，留给孤儿清扫',
      );
      expect(a.state, MangaOcrHostJobState.cancelled);
    });

    // 路线图 #3722 c41 遗留：关互联后立刻再开，app 新建的管理器原来从空队列起跑，
    // 旧管理器取消掉的整卷 isolate 还没退出时新任务就起了——两套模型同时在内存。
    test('关了立刻再开：新管理器的队列接在旧管理器执行体停下之后', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
      final MangaOcrHostJobManager oldManager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
      );
      await startedJob(oldManager, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);
      await oldManager.disposeAll().timeout(const Duration(seconds: 5));

      final MangaOcrHostJobManager newManager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
        runAfter: oldManager.whenExecutorsStopped,
      );
      final MangaOcrHostJob b = await startedJob(newManager, '卷二');
      await _settle();
      expect(service.startedDirs, hasLength(1), reason: '旧执行体停下之前新任务不起跑');
      expect(b.state, MangaOcrHostJobState.running, reason: '已受理、在排队');

      service.exits.first.complete();
      await _waitFor(() => service.startedDirs.length == 2);
      expect(service.startedDirs.last, b.dir.path);

      service.exits.last.complete();
      await newManager.cancelAndCleanup(b);
    });

    // 链要能传递：第二个管理器的任务还在排队（没起执行体，它自己的在停集合是空的）
    // 就又关又开，第三个管理器仍要等第一个管理器那只还没停下的执行体。
    test('连着关开两次：第三个管理器仍等第一个管理器的执行体停下', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
      final MangaOcrHostJobManager first = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
      );
      await startedJob(first, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);
      await first.disposeAll().timeout(const Duration(seconds: 5));

      final MangaOcrHostJobManager second = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
        runAfter: first.whenExecutorsStopped,
      );
      final MangaOcrHostJob b = await startedJob(second, '卷二');
      await _settle();
      expect(service.startedDirs, hasLength(1));
      await second.disposeAll().timeout(const Duration(seconds: 5));
      expect(b.state, MangaOcrHostJobState.cancelled);

      final MangaOcrHostJobManager third = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
        runAfter: second.whenExecutorsStopped,
      );
      final MangaOcrHostJob c = await startedJob(third, '卷三');
      await _settle();
      expect(
        service.startedDirs,
        hasLength(1),
        reason: '第一个管理器的执行体还没停：第三个管理器的任务不能起跑',
      );

      service.exits.first.complete();
      await _waitFor(() => service.startedDirs.length == 2);
      expect(service.startedDirs.last, c.dir.path, reason: '排队被取消的卷二不起跑');

      service.exits.last.complete();
      await third.cancelAndCleanup(c);
    });

    // app 每次开互联新建一个管理器：关了立刻再开时，旧管理器上途中的
    // cancelAndCleanup 回来不能删到新管理器的同卷任务头上。
    test('途中的 cancelAndCleanup 跨停机重开：不删新管理器同卷任务刚传的页图', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
      final MangaOcrHostJobManager oldManager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
      );
      final MangaOcrHostJob a = await startedJob(oldManager, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);

      bool cleaned = false;
      unawaited(oldManager.cancelAndCleanup(a).then((_) => cleaned = true));
      await oldManager.disposeAll().timeout(const Duration(seconds: 5));

      final MangaOcrHostJobManager newManager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
      );
      final MangaOcrHostJob b = newManager.createJob(volumeTitle: '卷一');
      expect(b.dir.path, a.dir.path, reason: '同卷落回同一个目录');
      expect(
        await newManager.uploadPage(b, name: 'p001.jpg', bytes: <int>[9]),
        isNull,
      );

      service.exits.first.complete();
      await _waitFor(() => cleaned);
      await oldManager.whenExecutorsStopped;
      expect(File(p.join(b.dir.path, 'p001.jpg')).readAsBytesSync(), <int>[
        9,
      ], reason: '新任务的页图还在');
      await newManager.cancelAndCleanup(b);
    });

    test('执行体收尾抛错：完成信号照补，后面的任务照常起跑', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      await startedJob(manager, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);
      await manager.disposeAll();
      final MangaOcrHostJob next = await startedJob(manager, '卷二');

      service.exits.first.completeError(StateError('engine close failed'));
      await manager.whenExecutorsStopped;
      await _waitFor(() => service.startedDirs.length == 2);
      expect(service.startedDirs.last, next.dir.path);

      service.exits.last.complete();
      await manager.cancelAndCleanup(next);
    });

    test('start 正在等模型状态时停机：回来不再起跑', () async {
      final _LingeringOcrService service = _LingeringOcrService()
        ..modelStatusGate = Completer<void>();
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      final MangaOcrHostJob job = manager.createJob(volumeTitle: '卷一');
      expect(
        await manager.uploadPage(job, name: 'p001.jpg', bytes: <int>[1]),
        isNull,
      );
      final Future<(int, String)?> starting = manager.start(job);
      await _waitFor(() => service.modelStatusCalls == 1);

      await manager.disposeAll();
      service.modelStatusGate!.complete();
      expect(await starting, (409, 'bad_state'));
      await _settle();
      expect(job.state, MangaOcrHostJobState.cancelled);
      expect(service.startedDirs, isEmpty, reason: '出了表的任务起跑之后没人能取消');
    });

    test('FushiSyncServer.stop() 不被还没停下的 OCR 执行体挂住', () async {
      final _LingeringOcrService service = _LingeringOcrService();
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
        port: 0,
        token: 'tok',
        mangaOcrJobs: manager,
      );
      await server.start();
      await startedJob(manager, '卷一');
      await _waitFor(() => service.startedDirs.length == 1);

      await server.stop().timeout(const Duration(seconds: 10));
      expect(service.cancelRequests, 1);
      expect(service.exits.single.isCompleted, isFalse, reason: '执行体此刻还没停');

      service.exits.single.complete();
      await manager.whenExecutorsStopped;
    });
  });
}
