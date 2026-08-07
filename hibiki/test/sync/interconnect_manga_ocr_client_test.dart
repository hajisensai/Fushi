/// 漫画 P3：互联「已配对主机代跑 OCR」客户端测试。
///
/// 对真实 [FushiSyncServer]（host 端 [MangaOcrService] 注 fake）走全流程：
/// 能力探测 → 创建 → 有限并发上传 → start → 轮询退避 → 取结果写本地 →
/// finished；外加能力缺失隐藏（老 host）、错误码映射、取消清理、退避纯函数。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/sync/hibiki_manga_ocr_host.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({this.ready = true});

  bool supported = true;
  bool ready;
  bool cancelled = false;
  Completer<void>? gate;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: ready,
        recognizerReady: ready,
        downloadedBytes: ready ? 1 : 0,
        totalBytes: 1,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<void> deleteModels() async {}

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) {
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    controller.onCancel = () => cancelled = true;
    controller.onListen = () {
      unawaited(() async {
        final List<String> pages = enumerateMangaPages(Directory(imageDirPath))
            .map((MangaOcrPageFile page) => page.relativeUrl)
            .toList(growable: false);
        if (!controller.isClosed) {
          controller.add(
            MangaOcrVolumeEvent.page(pagesDone: 1, pagesTotal: pages.length),
          );
        }
        final Completer<void>? g = gate;
        if (g != null) await g.future;
        if (controller.isClosed) return;
        final Directory outDir =
            Directory(p.join(imageDirPath, kMangaOcrOutDirName))
              ..createSync(recursive: true);
        final File out = File(p.join(outDir.path, kMangaOcrOutputFileName));
        out.writeAsStringSync(jsonEncode(<String, Object?>{
          'pages': <Object?>[
            for (final String url in pages)
              <String, Object?>{
                'url': url,
                'width': 10,
                'height': 20,
                'blocks': <Object?>[],
              },
          ],
        }));
        controller.add(MangaOcrVolumeEvent.finished(
          pagesTotal: pages.length,
          mangaJsonPath: out.path,
        ));
        await controller.close();
      }());
    };
    return controller.stream;
  }
}

void main() {
  late Directory tmpRoot;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('hbk_manga_ocr_cli');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  Future<FushiSyncServer> startHost(_FakeOcrService service,
      {bool wireManager = true, MangaOcrHostJobManager? manager}) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
      port: 0,
      token: 'tok',
      mangaOcrJobs: !wireManager
          ? null
          : manager ??
              MangaOcrHostJobManager(
                service: service,
                jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
              ),
    );
    await server.start();
    addTearDown(server.stop);
    await repo.setHibikiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}'),
    ]);
    await repo.setHibikiClientToken('tok');
    return server;
  }

  InterconnectMangaOcrClient buildClient() => InterconnectMangaOcrClient(
        repo: repo,
        pollDelay: (int attempt) => const Duration(milliseconds: 10),
      );

  Directory writeVolume() {
    final Directory dir = Directory(p.join(tmpRoot.path, 'vol'))
      ..createSync(recursive: true);
    // 乱序命名 + 一层子目录：验证自然序枚举与相对路径保留。
    File(p.join(dir.path, 'p010.jpg')).writeAsBytesSync(<int>[10]);
    File(p.join(dir.path, 'p2.jpg')).writeAsBytesSync(<int>[2]);
    final Directory sub = Directory(p.join(dir.path, 'extra'))
      ..createSync(recursive: true);
    File(p.join(sub.path, 'p001.png')).writeAsBytesSync(<int>[1]);
    return dir;
  }

  test(
      'probe: capable host → target; old host (no field) → null; '
      'no token → null', () async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    await startHost(service);
    final InterconnectMangaOcrClient client = buildClient();

    // 模型未下载的 host 仍返回 target（UI 要靠它讲清原因），但 usable 为假。
    final MangaOcrRemoteTarget? target = await client.probe();
    expect(target, isNotNull);
    expect(target!.capability.supported, isTrue);
    expect(target.capability.modelsReady, isFalse);
    expect(target.capability.usable, isFalse);
    expect(target.capability.modelsMissing, isTrue);

    // token 清空 → 隐藏。
    await repo.setHibikiClientToken(null);
    expect(await client.probe(), isNull);
  });

  // TODO-2635：`modelsReady` 三态。`null`（对端没报这个字段）绝不能和明确的
  // `false` 压成同一态——那会让这类对端上本可用的主机凭空消失。
  test('capability tri-state: true / false / absent are distinguishable', () {
    MangaOcrRemoteCapability? parse(Object? mangaOcr) =>
        MangaOcrRemoteCapability.fromCapabilitiesJson(
            <String, dynamic>{'mangaOcr': mangaOcr});

    final MangaOcrRemoteCapability ready =
        parse(<String, Object?>{'supported': true, 'modelsReady': true})!;
    expect(ready.modelsReady, isTrue);
    expect(ready.usable, isTrue);
    expect(ready.modelsMissing, isFalse);

    final MangaOcrRemoteCapability missing =
        parse(<String, Object?>{'supported': true, 'modelsReady': false})!;
    expect(missing.modelsReady, isFalse);
    expect(missing.usable, isFalse);
    expect(missing.modelsMissing, isTrue);

    // 字段缺失 = 未知 → 按可用处理（保持修复前行为，start 阶段兜底）。
    final MangaOcrRemoteCapability unknown =
        parse(<String, Object?>{'supported': true})!;
    expect(unknown.modelsReady, isNull);
    expect(unknown.usable, isTrue);
    expect(unknown.modelsMissing, isFalse);

    // 不支持：无论 modelsReady 怎么报都既不可用也不该显示「模型没下载」。
    final MangaOcrRemoteCapability unsupported =
        parse(<String, Object?>{'supported': false, 'modelsReady': false})!;
    expect(unsupported.usable, isFalse);
    expect(unsupported.modelsMissing, isFalse);

    // 整个 mangaOcr 对象缺失（真·老 host）→ null。
    expect(parse(null), isNull);
  });

  test('probe prefers a models-ready host over an earlier not-ready one',
      () async {
    Future<FushiSyncServer> spawn(bool ready) async {
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: Directory(p.join(tmpRoot.path, 'sync_$ready')).path,
        port: 0,
        token: 'tok',
        mangaOcrJobs: MangaOcrHostJobManager(
          service: _FakeOcrService(ready: ready),
          jobRoot: Directory(p.join(tmpRoot.path, 'jobs_$ready')),
        ),
      );
      await server.start();
      addTearDown(server.stop);
      return server;
    }

    final FushiSyncServer notReady = await spawn(false);
    final FushiSyncServer isReady = await spawn(true);
    // 未就绪的排在前面：修复前会被第一个命中并返回，就绪的那台永远选不上。
    await repo.setHibikiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${notReady.port}'),
      FushiClientUrl(url: 'http://127.0.0.1:${isReady.port}'),
    ]);
    await repo.setHibikiClientToken('tok');

    final MangaOcrRemoteTarget? target = await buildClient().probe();
    expect(target, isNotNull);
    expect(target!.baseUrl, 'http://127.0.0.1:${isReady.port}');
    expect(target.capability.usable, isTrue);
  });

  test('probe returns null against a host without manga OCR wiring (skew)',
      () async {
    await startHost(_FakeOcrService(), wireManager: false);
    expect(await buildClient().probe(), isNull);
  });

  test('full run: upload events → running → finished writes local manga.json',
      () async {
    final _FakeOcrService service = _FakeOcrService();
    await startHost(service);
    final InterconnectMangaOcrClient client = buildClient();
    final Directory volume = writeVolume();

    final MangaOcrRemoteTarget target = (await client.probe())!;
    final List<MangaOcrRemoteEvent> events = <MangaOcrRemoteEvent>[];
    await client
        .run(target: target, imageDirPath: volume.path, volumeTitle: '卷二')
        .forEach(events.add);

    // 上传阶段：3 页逐一回报。
    final List<MangaOcrRemoteEvent> uploads =
        events.where((MangaOcrRemoteEvent e) => e.uploading).toList();
    expect(uploads, hasLength(3));
    expect(uploads.last.done, 3);
    expect(uploads.last.total, 3);

    // finished：manga.json 已写到 <所选文件夹>/manga_ocr_out/manga.json。
    final MangaOcrRemoteEvent finished = events.last;
    expect(finished.finished, isTrue);
    final String expectedPath =
        p.join(volume.path, kMangaOcrOutDirName, kMangaOcrOutputFileName);
    expect(
        p.canonicalize(finished.mangaJsonPath!), p.canonicalize(expectedPath));
    final Map<String, dynamic> manga =
        jsonDecode(File(expectedPath).readAsStringSync())
            as Map<String, dynamic>;
    final List<String> urls = <String>[
      for (final dynamic page in manga['pages'] as List<dynamic>)
        (page as Map<String, dynamic>)['url'] as String,
    ];
    // 自然序（p2 < p010）+ 子目录相对路径保留。
    expect(urls, <String>['extra/p001.png', 'p2.jpg', 'p010.jpg']);
  });

  test('models not ready on host maps to models_not_ready', () async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    await startHost(service);
    final InterconnectMangaOcrClient client = buildClient();
    final Directory volume = writeVolume();
    final MangaOcrRemoteTarget target = (await client.probe())!;

    await expectLater(
      client.run(target: target, imageDirPath: volume.path).drain<void>(),
      throwsA(isA<MangaOcrRemoteException>().having(
          (MangaOcrRemoteException e) => e.code, 'code', 'models_not_ready')),
    );
  });

  test('empty local folder fails fast with no_pages', () async {
    final _FakeOcrService service = _FakeOcrService();
    await startHost(service);
    final InterconnectMangaOcrClient client = buildClient();
    final Directory empty = Directory(p.join(tmpRoot.path, 'empty'))
      ..createSync(recursive: true);
    final MangaOcrRemoteTarget target = (await client.probe())!;
    await expectLater(
      client.run(target: target, imageDirPath: empty.path).drain<void>(),
      throwsA(isA<MangaOcrRemoteException>()
          .having((MangaOcrRemoteException e) => e.code, 'code', 'no_pages')),
    );
  });

  test('cancelling the run subscription cleans up the host job', () async {
    final _FakeOcrService service = _FakeOcrService()..gate = Completer<void>();
    final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
    );
    await startHost(service, manager: manager);
    final InterconnectMangaOcrClient client = buildClient();
    final Directory volume = writeVolume();
    final MangaOcrRemoteTarget target = (await client.probe())!;

    final Completer<void> sawRemote = Completer<void>();
    final StreamSubscription<MangaOcrRemoteEvent> sub = client
        .run(target: target, imageDirPath: volume.path)
        .listen((MangaOcrRemoteEvent event) {
      if (!event.uploading && !event.finished && !sawRemote.isCompleted) {
        sawRemote.complete();
      }
    });
    await sawRemote.future.timeout(const Duration(seconds: 10));
    expect(manager.jobCount, 1);
    await sub.cancel();
    // 取消后 host 侧任务被 DELETE（页边界停 + 出表）。轮询等 best-effort 清理。
    for (int i = 0; i < 100 && manager.jobCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(manager.jobCount, 0);
    expect(service.cancelled, isTrue);
    // 本地不落 manga.json（任务没跑完）。
    expect(
      File(p.join(volume.path, kMangaOcrOutDirName, kMangaOcrOutputFileName))
          .existsSync(),
      isFalse,
    );
    service.gate?.complete();
    service.gate = null;
  });

  test('poll delay backs off monotonically and caps at 5s', () {
    Duration previous = Duration.zero;
    for (int attempt = 0; attempt < 30; attempt++) {
      final Duration delay = mangaOcrPollDelay(attempt);
      expect(delay, greaterThanOrEqualTo(previous));
      expect(delay.inMilliseconds, lessThanOrEqualTo(5000));
      previous = delay;
    }
    expect(mangaOcrPollDelay(0), const Duration(milliseconds: 500));
    expect(mangaOcrPollDelay(29), const Duration(milliseconds: 5000));
  });
}
