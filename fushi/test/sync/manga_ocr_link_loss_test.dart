// 漫画 OCR client 的断连子状态（remote-job-client-lifecycle 的 OCR 部分）：观测失败
// （传输层）≠ 任务失败；断连期间发 `running(reconnecting: true)`，从第一次失败起超过
// 容忍窗才以 `transport == true` 的本地化错误收尾，并尽力清理 host 任务。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// host 端 OCR：报一页进度后等 [gate]（null 则直接完成）再写 manga.json。
class _GatedOcrService implements MangaOcrService {
  Completer<void>? gate;

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
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    controller.onListen = () {
      unawaited(() async {
        final List<String> pages = enumerateMangaPages(Directory(imageDirPath))
            .map((MangaOcrPageFile page) => page.relativeUrl)
            .toList(growable: false);
        controller.add(
          MangaOcrVolumeEvent.page(pagesDone: 1, pagesTotal: pages.length),
        );
        final Completer<void>? g = gate;
        if (g != null) await g.future;
        if (controller.isClosed) return;
        final Directory outDir = Directory(
          p.join(imageDirPath, kMangaOcrOutDirName),
        )..createSync(recursive: true);
        final File out = File(p.join(outDir.path, kMangaOcrOutputFileName))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{'pages': <Object?>[]}),
          );
        controller.add(
          MangaOcrVolumeEvent.finished(
            pagesTotal: pages.length,
            mangaJsonPath: out.path,
          ),
        );
        await controller.close();
      }());
    };
    return controller.stream;
  }
}

/// 状态 GET 交给 [onStatusGet] 决定是否注入故障；记录 DELETE 发生时已看到的状态 GET 数。
class _FaultClient extends http.BaseClient {
  _FaultClient(this.onStatusGet);

  final http.Client _inner = http.Client();
  final Future<http.StreamedResponse>? Function(int nth) onStatusGet;
  int statusGets = 0;
  final List<int> deletesAfterStatusGets = <int>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'DELETE') deletesAfterStatusGets.add(statusGets);
    if (request.method == 'GET' &&
        RegExp(r'^/api/ocr/job/[^/]+$').hasMatch(request.url.path)) {
      statusGets += 1;
      final Future<http.StreamedResponse>? injected = onStatusGet(statusGets);
      if (injected != null) return injected;
    }
    return _inner.send(request);
  }

  /// 同一个实例经 `plainClientFactory` 交给 probe 与 run，各自用完会调 [close]：
  /// 这里不关底层 client，由测试的 tearDown 调 [shutdown] 关。
  @override
  void close() {}

  void shutdown() => _inner.close();
}

void main() {
  late Directory tmpRoot;
  late FushiDatabase db;
  late SyncRepository repo;
  late _GatedOcrService service;
  late MangaOcrHostJobManager manager;

  setUp(() async {
    tmpRoot = Directory.systemTemp.createTempSync('hbk_manga_ocr_link');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    service = _GatedOcrService();
    manager = MangaOcrHostJobManager(
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
    addTearDown(server.stop);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}'),
    ]);
    await repo.setFushiClientToken('tok');
  });

  tearDown(() async {
    final Completer<void>? g = service.gate;
    if (g != null && !g.isCompleted) g.complete();
    await db.close();
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  String writeVolume() {
    final Directory dir = Directory(p.join(tmpRoot.path, 'vol'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'p1.jpg')).writeAsBytesSync(<int>[1]);
    File(p.join(dir.path, 'p2.jpg')).writeAsBytesSync(<int>[2]);
    return dir.path;
  }

  test('transport flag: only the named constructor marks transport', () {
    expect(const MangaOcrRemoteException('auth').transport, isFalse);
    expect(const MangaOcrRemoteException('http', 'x').transport, isFalse);
    expect(const MangaOcrRemoteException.transport('http').transport, isTrue);
  });

  test('a short outage emits exactly one reconnecting event', () async {
    final _FaultClient wire = _FaultClient(
      (int nth) => nth <= 2
          ? Future<http.StreamedResponse>.error(
              const SocketException('link dropped'),
            )
          : null,
    );
    addTearDown(wire.shutdown);
    final InterconnectMangaOcrClient client = InterconnectMangaOcrClient(
      repo: repo,
      plainClientFactory: () => wire,
      pollDelay: (int attempt) => const Duration(milliseconds: 10),
    );
    final MangaOcrRemoteTarget target = (await client.probe())!;

    final List<MangaOcrRemoteEvent> events = <MangaOcrRemoteEvent>[];
    await client
        .run(target: target, imageDirPath: writeVolume())
        .forEach(events.add);
    expect(
      events.where((MangaOcrRemoteEvent e) => e.reconnecting),
      hasLength(1),
    );
    expect(events.last.finished, isTrue);
    expect(events.last.reconnecting, isFalse);
  });

  test('an outage beyond the tolerance window ends with a localized '
      'transport error and deletes the host job once', () async {
    service.gate = Completer<void>();
    DateTime clock = DateTime(2026, 11, 10, 12);
    final _FaultClient wire = _FaultClient((int nth) {
      clock = clock.add(const Duration(minutes: 4));
      return Future<http.StreamedResponse>.error(
        const SocketException('link dropped'),
      );
    });
    addTearDown(wire.shutdown);
    final InterconnectMangaOcrClient client = InterconnectMangaOcrClient(
      repo: repo,
      plainClientFactory: () => wire,
      pollDelay: (int attempt) => const Duration(milliseconds: 10),
      linkLossTolerance: const Duration(minutes: 10),
      now: () => clock,
    );
    final MangaOcrRemoteTarget target = (await client.probe())!;

    final List<MangaOcrRemoteEvent> events = <MangaOcrRemoteEvent>[];
    Object? error;
    await client
        .run(target: target, imageDirPath: writeVolume())
        .forEach(events.add)
        .catchError((Object e) => error = e);

    expect(
      error,
      isA<MangaOcrRemoteException>()
          .having((MangaOcrRemoteException e) => e.code, 'code', 'http')
          .having((MangaOcrRemoteException e) => e.transport, 'transport', true)
          .having(
            (MangaOcrRemoteException e) => e.detail,
            'detail',
            t.interconnect_remote_job_disconnected(minutes: '10'),
          ),
    );
    // 第 1 次失败起算：4、8、12 分钟——第 4 次失败（距起点 12 分钟）判定断连。
    expect(wire.statusGets, 4);
    expect(
      events.where((MangaOcrRemoteEvent e) => e.reconnecting),
      hasLength(1),
    );
    for (int i = 0; i < 150 && manager.jobCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(manager.jobCount, 0);
    expect(wire.deletesAfterStatusGets, <int>[4]);
  });
}
