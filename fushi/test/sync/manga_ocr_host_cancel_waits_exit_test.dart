/// BUG-4800 在互联主机一侧的落点：[MangaOcrService.ocrFolder] 取消订阅的 Future
/// 现在等到执行体真正停下（本地模型 = 整卷 isolate 已退出）才完成，
/// [MangaOcrHostJobManager.cancelAndCleanup] await 的就是它。
///
/// 主机的串行队列与全局名额是同一个问题：旧 isolate 还占着整套模型时就放行下一
/// 个任务，主机上就是两套模型同时在内存；页图也不能在旧 isolate 还在读的时候删。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 每次 [ocrFolder] 起一个挂着不结束的任务；取消订阅的 Future 等 [exit] 才完成
/// （生产实现里是整卷 isolate 退出）。
class _LingeringOcrService implements MangaOcrService {
  final List<Completer<void>> exits = <Completer<void>>[];
  final List<String> startedDirs = <String>[];
  int cancelRequests = 0;

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
}
