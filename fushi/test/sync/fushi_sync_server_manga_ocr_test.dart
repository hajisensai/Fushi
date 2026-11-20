/// 漫画 P3：互联 host 代跑 OCR 的 server 端点 + 任务管理器测试。
///
/// host 端 [MangaOcrService] 注入 fake（不下载模型、不跑真 ORT）：
/// - 全流程：创建 → 逐页上传 → start → 轮询 → result；
/// - 未鉴权 401 / 未接线 404 / capabilities 能力协商；
/// - 模型未就绪 503 models_not_ready；
/// - 上传页名穿越拒绝；
/// - 串行单并发队列（第二个 job 排队等第一个跑完）;
/// - 取消清理：页图删除、`manga_ocr_out/` 断点缓存保留（同卷重传后续传）。
/// - 逐页上传带源 mtime：重传同卷时真的命中逐页断点缓存（BUG-4817）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrFilePageCache,
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart' show OcrBlock, OcrPageResult;
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// Fake host OCR 服务：按上传目录枚举页图，写 `manga_ocr_out/manga.json`。
/// [gate] 非 null 时在 finished 前等待（测串行队列/取消）。
/// 页图照常落盘、但拒绝改修改时间的文件（模拟 FAT / exFAT 表示不了的时间，或
/// 页图在落盘与设时间之间被删）。只实现 `uploadPage` 用到的成员。
class _MtimeRejectingFile implements File {
  _MtimeRejectingFile(this._real, this._onRejected);

  final File _real;
  final void Function() _onRejected;

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await _real.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  Future<void> setLastModified(DateTime time) async {
    _onRejected();
    throw FileSystemException('Failed to set file modification time', path);
  }

  @override
  File renameSync(String newPath) => _real.renameSync(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({this.supported = true, this.ready = true});

  bool supported;
  bool ready;
  int started = 0;
  Completer<void>? gate;
  bool lastCancelled = false;
  String? lastVolumeTitle;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
    detectorReady: ready,
    recognizerReady: ready,
    diskBytes: ready ? 1 : 0,
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
    started += 1;
    lastVolumeTitle = volumeTitle;
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    controller.onCancel = () => lastCancelled = true;
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
        final Directory outDir = Directory(
          p.join(imageDirPath, kMangaOcrOutDirName),
        )..createSync(recursive: true);
        final File out = File(p.join(outDir.path, kMangaOcrOutputFileName));
        out.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'pages': <Object?>[
              for (final String url in pages)
                <String, Object?>{
                  'url': url,
                  'width': 100,
                  'height': 200,
                  'blocks': <Object?>[],
                },
            ],
          }),
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

/// 共享卷目录用例的脚本化 fake：第 N 次 [ocrFolder] 取 [failFirst] 决定行为——
/// true = 流立即抛错（任务进 error）；false = 流挂起不结束（任务停在 running）。
class _ScriptedOcrService implements MangaOcrService {
  _ScriptedOcrService(this.script);

  final List<bool> script;
  int _calls = 0;
  final List<StreamController<MangaOcrVolumeEvent>> _hanging =
      <StreamController<MangaOcrVolumeEvent>>[];

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
    final bool fail = script[_calls++];
    if (fail) {
      return Stream<MangaOcrVolumeEvent>.error(StateError('scripted failure'));
    }
    final StreamController<MangaOcrVolumeEvent> controller =
        StreamController<MangaOcrVolumeEvent>();
    _hanging.add(controller);
    return controller.stream;
  }

  Future<void> closeAll() async {
    for (final StreamController<MangaOcrVolumeEvent> c in _hanging) {
      await c.close();
    }
  }
}

Future<void> _waitState(MangaOcrHostJob job, MangaOcrHostJobState state) async {
  for (int i = 0; i < 200 && job.state != state; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(job.state, state);
}

Future<HttpClientResponse> _request(
  int port,
  String method,
  String path, {
  String? token,
  Object? jsonBody,
  List<int>? bodyBytes,
}) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest r = await c.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  if (token != null) {
    r.headers.set(
      'authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
  }
  if (jsonBody != null) {
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(jsonBody));
  } else if (bodyBytes != null) {
    r.add(bodyBytes);
  }
  return r.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async =>
    jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;

void main() {
  late Directory tmpRoot;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('hbk_manga_ocr');
  });

  tearDown(() {
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  FushiSyncServer buildServer(
    _FakeOcrService service, {
    MangaOcrHostJobManager? manager,
  }) {
    return FushiSyncServer(
      syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
      port: 0,
      token: 'tok',
      mangaOcrJobs:
          manager ??
          MangaOcrHostJobManager(
            service: service,
            jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
          ),
    );
  }

  test('full flow: create → upload → start → poll → result', () async {
    final _FakeOcrService service = _FakeOcrService();
    final FushiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);

    // 创建任务。
    final HttpClientResponse createResp = await _request(
      server.port,
      'POST',
      '/api/ocr/job',
      token: 'tok',
      jsonBody: <String, Object?>{'volumeTitle': '卷一', 'pageCount': 2},
    );
    expect(createResp.statusCode, 200);
    final Map<String, dynamic> created = await _json(createResp);
    final String jobId = created['jobId'] as String;
    expect(jobId, isNotEmpty);
    expect(created['pagesExpected'], 2);

    // 逐页上传（含一层子目录）。
    final HttpClientResponse up1 = await _request(
      server.port,
      'PUT',
      '/api/ocr/job/$jobId/page/0'
          '?name=${Uri.encodeQueryComponent('p001.jpg')}',
      token: 'tok',
      bodyBytes: <int>[1, 2, 3],
    );
    expect(up1.statusCode, 200);
    final HttpClientResponse up2 = await _request(
      server.port,
      'PUT',
      '/api/ocr/job/$jobId/page/1'
          '?name=${Uri.encodeQueryComponent('sub/p002.jpg')}',
      token: 'tok',
      bodyBytes: <int>[4, 5, 6],
    );
    expect(up2.statusCode, 200);

    // 上传阶段状态。
    Map<String, dynamic> status = await _json(
      await _request(server.port, 'GET', '/api/ocr/job/$jobId', token: 'tok'),
    );
    expect(status['state'], 'uploading');
    expect(status['pagesUploaded'], 2);

    // result 在完成前是 409 not_done。
    final HttpClientResponse early = await _request(
      server.port,
      'GET',
      '/api/ocr/job/$jobId/result',
      token: 'tok',
    );
    expect(early.statusCode, 409);

    // start → 轮询到 done。
    final HttpClientResponse startResp = await _request(
      server.port,
      'POST',
      '/api/ocr/job/$jobId/start',
      token: 'tok',
    );
    expect(startResp.statusCode, 200);
    for (int i = 0; i < 100; i++) {
      status = await _json(
        await _request(server.port, 'GET', '/api/ocr/job/$jobId', token: 'tok'),
      );
      if (status['state'] == 'done') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status['state'], 'done');
    expect(status['pagesTotal'], 2);
    expect(service.lastVolumeTitle, '卷一');

    // result：manga.json 内容（页 url 保留相对子目录、自然序）。
    final HttpClientResponse resultResp = await _request(
      server.port,
      'GET',
      '/api/ocr/job/$jobId/result',
      token: 'tok',
    );
    expect(resultResp.statusCode, 200);
    final Map<String, dynamic> manga = await _json(resultResp);
    final List<dynamic> pages = manga['pages'] as List<dynamic>;
    expect(pages, hasLength(2));
    expect((pages[0] as Map<String, dynamic>)['url'], 'p001.jpg');
    expect((pages[1] as Map<String, dynamic>)['url'], 'sub/p002.jpg');
  });

  test('unauthenticated /api/ocr/* is 401', () async {
    final FushiSyncServer server = buildServer(_FakeOcrService());
    await server.start();
    addTearDown(server.stop);
    final HttpClientResponse resp = await _request(
      server.port,
      'POST',
      '/api/ocr/job',
      jsonBody: const <String, Object?>{},
    );
    expect(resp.statusCode, 401);
  });

  test(
    'endpoints are 404 and capabilities has no mangaOcr when not wired',
    () async {
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
        port: 0,
        token: 'tok',
      );
      await server.start();
      addTearDown(server.stop);
      final HttpClientResponse resp = await _request(
        server.port,
        'POST',
        '/api/ocr/job',
        token: 'tok',
        jsonBody: const <String, Object?>{},
      );
      expect(resp.statusCode, 404);
      final Map<String, dynamic> caps = await _json(
        await _request(server.port, 'GET', '/api/capabilities', token: 'tok'),
      );
      expect(caps.containsKey('mangaOcr'), isFalse);
    },
  );

  test('capabilities reports mangaOcr supported/modelsReady', () async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    final FushiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);
    Map<String, dynamic> caps = await _json(
      await _request(server.port, 'GET', '/api/capabilities', token: 'tok'),
    );
    expect(caps['mangaOcr'], <String, Object?>{
      'supported': true,
      'modelsReady': false,
    });
    service.ready = true;
    caps = await _json(
      await _request(server.port, 'GET', '/api/capabilities', token: 'tok'),
    );
    expect(caps['mangaOcr'], <String, Object?>{
      'supported': true,
      'modelsReady': true,
    });
  });

  test('start with models not ready → 503 models_not_ready', () async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    final FushiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);
    final Map<String, dynamic> created = await _json(
      await _request(
        server.port,
        'POST',
        '/api/ocr/job',
        token: 'tok',
        jsonBody: const <String, Object?>{},
      ),
    );
    final String jobId = created['jobId'] as String;
    await _request(
      server.port,
      'PUT',
      '/api/ocr/job/$jobId/page/0?name=a.jpg',
      token: 'tok',
      bodyBytes: <int>[1],
    );
    final HttpClientResponse resp = await _request(
      server.port,
      'POST',
      '/api/ocr/job/$jobId/start',
      token: 'tok',
    );
    expect(resp.statusCode, 503);
    expect((await _json(resp))['error'], 'models_not_ready');
    expect(service.started, 0);
  });

  test('unsupported platform → 503 not_supported', () async {
    final _FakeOcrService service = _FakeOcrService(supported: false);
    final FushiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);
    final Map<String, dynamic> created = await _json(
      await _request(
        server.port,
        'POST',
        '/api/ocr/job',
        token: 'tok',
        jsonBody: const <String, Object?>{},
      ),
    );
    final String jobId = created['jobId'] as String;
    await _request(
      server.port,
      'PUT',
      '/api/ocr/job/$jobId/page/0?name=a.jpg',
      token: 'tok',
      bodyBytes: <int>[1],
    );
    final HttpClientResponse resp = await _request(
      server.port,
      'POST',
      '/api/ocr/job/$jobId/start',
      token: 'tok',
    );
    expect(resp.statusCode, 503);
    expect((await _json(resp))['error'], 'not_supported');
  });

  test('page upload rejects traversal / absolute / reserved names', () async {
    final FushiSyncServer server = buildServer(_FakeOcrService());
    await server.start();
    addTearDown(server.stop);
    final Map<String, dynamic> created = await _json(
      await _request(
        server.port,
        'POST',
        '/api/ocr/job',
        token: 'tok',
        jsonBody: const <String, Object?>{},
      ),
    );
    final String jobId = created['jobId'] as String;
    for (final String bad in <String>[
      '../evil.jpg',
      'sub/../../evil.jpg',
      '/abs.jpg',
      'manga_ocr_out/poison.json',
      '',
    ]) {
      final HttpClientResponse resp = await _request(
        server.port,
        'PUT',
        '/api/ocr/job/$jobId/page/0?name=${Uri.encodeQueryComponent(bad)}',
        token: 'tok',
        bodyBytes: <int>[1],
      );
      expect(resp.statusCode, 400, reason: 'name=$bad must be rejected');
    }
  });

  test('unknown job → 404 unknown_job', () async {
    final FushiSyncServer server = buildServer(_FakeOcrService());
    await server.start();
    addTearDown(server.stop);
    final HttpClientResponse resp = await _request(
      server.port,
      'GET',
      '/api/ocr/job/nope',
      token: 'tok',
    );
    expect(resp.statusCode, 404);
    expect((await _json(resp))['error'], 'unknown_job');
  });

  test('serial queue: second job waits until the first completes', () async {
    final _FakeOcrService service = _FakeOcrService()..gate = Completer<void>();
    final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
    );
    final MangaOcrHostJob first = manager.createJob(volumeTitle: 'A');
    final MangaOcrHostJob second = manager.createJob(volumeTitle: 'B');
    await manager.uploadPage(first, name: 'a.jpg', bytes: <int>[1]);
    await manager.uploadPage(second, name: 'b.jpg', bytes: <int>[2]);

    expect(await manager.start(first), isNull);
    expect(await manager.start(second), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // 第一个占用队列，第二个排队（服务只被拉起一次）。
    expect(service.started, 1);
    expect(first.state, MangaOcrHostJobState.running);
    expect(second.state, MangaOcrHostJobState.running);

    // 放行第一个 → 第二个自动开跑并完成。
    service.gate!.complete();
    service.gate = null;
    for (int i = 0; i < 100 && second.state != MangaOcrHostJobState.done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(first.state, MangaOcrHostJobState.done);
    expect(second.state, MangaOcrHostJobState.done);
    expect(service.started, 2);
  });

  test(
    'DELETE cancels at page boundary, keeps checkpoint cache for resume',
    () async {
      final _FakeOcrService service = _FakeOcrService()
        ..gate = Completer<void>();
      final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
      );
      final FushiSyncServer server = buildServer(service, manager: manager);
      await server.start();
      addTearDown(server.stop);

      final Map<String, dynamic> created = await _json(
        await _request(
          server.port,
          'POST',
          '/api/ocr/job',
          token: 'tok',
          jsonBody: <String, Object?>{'volumeTitle': '同卷'},
        ),
      );
      final String jobId = created['jobId'] as String;
      await _request(
        server.port,
        'PUT',
        '/api/ocr/job/$jobId/page/0?name=p001.jpg',
        token: 'tok',
        bodyBytes: <int>[1, 2, 3],
      );
      await _request(
        server.port,
        'POST',
        '/api/ocr/job/$jobId/start',
        token: 'tok',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 任务目录：页图已落盘；模拟逐页断点缓存已写。
      final Directory jobDir = jobRoot.listSync().whereType<Directory>().single;
      expect(File(p.join(jobDir.path, 'p001.jpg')).existsSync(), isTrue);
      final File cacheFile = File(
        p.join(jobDir.path, kMangaOcrOutDirName, '_pages', 'p001.jpg.json'),
      )..createSync(recursive: true);

      final HttpClientResponse delResp = await _request(
        server.port,
        'DELETE',
        '/api/ocr/job/$jobId',
        token: 'tok',
      );
      expect(delResp.statusCode, 200);
      expect(service.lastCancelled, isTrue, reason: '订阅取消 = 页边界中止');
      // 页图删除、断点缓存保留。
      expect(File(p.join(jobDir.path, 'p001.jpg')).existsSync(), isFalse);
      expect(cacheFile.existsSync(), isTrue);
      expect(manager.jobCount, 0);
      // 任务已出表：再查 404。
      final HttpClientResponse gone = await _request(
        server.port,
        'GET',
        '/api/ocr/job/$jobId',
        token: 'tok',
      );
      expect(gone.statusCode, 404);
      // 放行 fake 的挂起循环，避免泄漏 pending timer。
      service.gate?.complete();
      service.gate = null;

      // 同卷新任务落回同一目录 → 断点缓存可续传。
      final Map<String, dynamic> again = await _json(
        await _request(
          server.port,
          'POST',
          '/api/ocr/job',
          token: 'tok',
          jsonBody: <String, Object?>{'volumeTitle': '同卷'},
        ),
      );
      expect(again['jobId'], isNot(jobId));
      final Directory jobDir2 = jobRoot
          .listSync()
          .whereType<Directory>()
          .single;
      expect(p.canonicalize(jobDir2.path), p.canonicalize(jobDir.path));

      // 取消不得卡死串行队列（cancelAndCleanup 补完成信号的回归守卫）：
      // 重传后 start 新任务必须能跑完。
      final String jobId2 = again['jobId'] as String;
      await _request(
        server.port,
        'PUT',
        '/api/ocr/job/$jobId2/page/0?name=p001.jpg',
        token: 'tok',
        bodyBytes: <int>[1, 2, 3],
      );
      await _request(
        server.port,
        'POST',
        '/api/ocr/job/$jobId2/start',
        token: 'tok',
      );
      Map<String, dynamic> status = const <String, dynamic>{};
      for (int i = 0; i < 100; i++) {
        status = await _json(
          await _request(
            server.port,
            'GET',
            '/api/ocr/job/$jobId2',
            token: 'tok',
          ),
        );
        if (status['state'] == 'done') break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(status['state'], 'done', reason: '取消后队列必须继续放行新任务');
    },
  );

  // BUG-4817：逐页断点缓存按「页名 + 大小 + 修改时间」认页。取消删页图、重传是
  // 新写，页图的修改时间若是 host 落盘那一刻，保留下来的缓存永远对不上。
  test(
    'page upload stamps the source mtime so the checkpoint cache hits after re-upload',
    () async {
      final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: _FakeOcrService(),
        jobRoot: jobRoot,
      );
      final FushiSyncServer server = buildServer(
        _FakeOcrService(),
        manager: manager,
      );
      await server.start();
      addTearDown(server.stop);

      final int sourceMs = DateTime.utc(
        2024,
        3,
        5,
        12,
        30,
      ).millisecondsSinceEpoch;
      String lastJobId = '';
      Future<void> cancelLast() async {
        final HttpClientResponse deleted = await _request(
          server.port,
          'DELETE',
          '/api/ocr/job/$lastJobId',
          token: 'tok',
        );
        expect(deleted.statusCode, 200);
        await deleted.drain<void>();
      }

      Future<Directory> uploadFreshJob({int? mtime}) async {
        final Map<String, dynamic> created = await _json(
          await _request(
            server.port,
            'POST',
            '/api/ocr/job',
            token: 'tok',
            jsonBody: <String, Object?>{'volumeTitle': '同卷'},
          ),
        );
        final HttpClientResponse put = await _request(
          server.port,
          'PUT',
          '/api/ocr/job/${created['jobId']}/page/0?name=p001.jpg'
              '${mtime == null ? '' : '&mtime=$mtime'}',
          token: 'tok',
          bodyBytes: <int>[1, 2, 3],
        );
        expect(put.statusCode, 200);
        await put.drain<void>();
        lastJobId = created['jobId'] as String;
        return manager.job(lastJobId)!.dir;
      }

      // 真的逐页缓存类（本地 OCR 与 host 共用），不是空文件占位。
      MangaOcrFilePageCache cacheOf(Directory jobDir) => MangaOcrFilePageCache(
        cacheDir: Directory(p.join(jobDir.path, kMangaOcrOutDirName, '_pages')),
        pageNames: const <String>['p001.jpg'],
        pageFiles: <File>[File(p.join(jobDir.path, 'p001.jpg'))],
      );

      final Directory jobDir = await uploadFreshJob(mtime: sourceMs);
      expect(
        File(
          p.join(jobDir.path, 'p001.jpg'),
        ).lastModifiedSync().millisecondsSinceEpoch,
        sourceMs,
      );
      await cacheOf(jobDir).write(
        'vol',
        const OcrPageResult(
          pageIndex: 0,
          imageWidth: 100,
          imageHeight: 200,
          blocks: <OcrBlock>[],
        ),
      );

      // 取消：页图删掉、缓存留着；重传同一页（同字节、同源 mtime）→ 命中。
      await cancelLast();
      expect(File(p.join(jobDir.path, 'p001.jpg')).existsSync(), isFalse);
      final Directory again = await uploadFreshJob(mtime: sourceMs);
      expect(p.canonicalize(again.path), p.canonicalize(jobDir.path));
      final OcrPageResult? hit = await cacheOf(again).read('vol', 0);
      expect(hit, isNotNull, reason: '同卷重传必须命中已识别页的缓存');
      expect(hit!.imageWidth, 100);

      // 源文件改过（mtime 不同）→ 不命中，照常重新识别。
      await cancelLast();
      final Directory changed = await uploadFreshJob(mtime: sourceMs + 1000);
      expect(await cacheOf(changed).read('vol', 0), isNull);

      // 老客户端不带 mtime：行为不变（页图是 host 落盘时间，不是源时间）。
      await cancelLast();
      final Directory legacy = await uploadFreshJob();
      expect(
        File(
          p.join(legacy.path, 'p001.jpg'),
        ).lastModifiedSync().millisecondsSinceEpoch,
        isNot(sourceMs),
      );
    },
  );

  // 设修改时间只为续传：文件系统不收这个时间 / 页图在两步之间被删时，页图已经
  // 写好，上传照常成功（只是这页不续传），不能变成 500。
  test(
    'page upload still succeeds when the file system rejects the source mtime',
    () async {
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: _FakeOcrService(),
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      final MangaOcrHostJob job = manager.createJob(volumeTitle: '同卷');
      int rejected = 0;
      final String? refusal = await IOOverrides.runZoned<Future<String?>>(
        () => manager.uploadPage(
          job,
          name: 'p001.jpg',
          bytes: <int>[1, 2, 3],
          sourceModified: DateTime.utc(2024, 3, 5),
        ),
        createFile: (String path) => _MtimeRejectingFile(
          Zone.root.run<File>(() => File(path)),
          () => rejected += 1,
        ),
      );
      expect(rejected, 1, reason: '确实走到了设修改时间那一步');
      expect(refusal, isNull);
      expect(job.pagesUploaded, 1);
      expect(job.state, MangaOcrHostJobState.uploading);
      expect(File(p.join(job.dir.path, 'p001.jpg')).readAsBytesSync(), <int>[
        1,
        2,
        3,
      ]);
    },
  );

  // 写盘途中任务被取消：取消清理删光页图并出表之后，晚到的这页不能落进卷目录
  // （同卷下一个任务落回同一个 vol_<slug>，会把它当自己的页识别），也不能把已取消
  // 的任务写回 uploading。
  test(
    'page upload racing a cancel leaves no page and no uploading state',
    () async {
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: _FakeOcrService(),
        jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
      );
      final MangaOcrHostJob job = manager.createJob(volumeTitle: '同卷');
      expect(
        await manager.uploadPage(job, name: 'p001.jpg', bytes: <int>[1]),
        isNull,
      );

      final Future<String?> inFlight = manager.uploadPage(
        job,
        name: 'ch2/p002.jpg',
        bytes: List<int>.filled(1 << 20, 7),
      );
      await manager.cancelAndCleanup(job);
      final String? refusal = await inFlight;

      expect(refusal, 'bad_state');
      expect(job.state, MangaOcrHostJobState.cancelled);
      expect(job.pagesUploaded, 1);
      final List<String> left = job.dir.existsSync()
          ? job.dir
                .listSync(recursive: true)
                .whereType<File>()
                .map((File f) => p.relative(f.path, from: job.dir.path))
                .toList()
          : <String>[];
      expect(left, isEmpty, reason: '取消之后卷目录里不能留页图或暂存文件');

      // 同卷新任务落回同一目录：只看得到自己上传的页。
      final MangaOcrHostJob next = manager.createJob(volumeTitle: '同卷');
      expect(next.dir.path, job.dir.path);
      expect(
        await manager.uploadPage(next, name: 'p001.jpg', bytes: <int>[9]),
        isNull,
      );
      expect(
        next.dir
            .listSync(recursive: true)
            .whereType<File>()
            .map((File f) => p.relative(f.path, from: next.dir.path)),
        <String>['p001.jpg'],
      );
    },
  );

  test('mtime query: non-integer / out-of-range values are ignored', () {
    expect(parseMangaOcrSourceModified(null), isNull);
    expect(parseMangaOcrSourceModified(''), isNull);
    expect(parseMangaOcrSourceModified('abc'), isNull);
    expect(parseMangaOcrSourceModified('0'), isNull);
    expect(parseMangaOcrSourceModified('-5'), isNull);
    expect(parseMangaOcrSourceModified('999999999999999999'), isNull);
    expect(
      parseMangaOcrSourceModified('1709641800000')!.millisecondsSinceEpoch,
      1709641800000,
    );
  });

  test('expired jobs are pruned with their directories (TTL)', () async {
    DateTime now = DateTime(2026, 7, 24, 12);
    final _FakeOcrService service = _FakeOcrService();
    final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
    final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
      service: service,
      jobRoot: jobRoot,
      now: () => now,
      jobTtl: const Duration(minutes: 30),
    );
    final MangaOcrHostJob job = manager.createJob(volumeTitle: 'stale');
    await manager.uploadPage(job, name: 'a.jpg', bytes: <int>[1]);
    expect(manager.jobCount, 1);
    now = now.add(const Duration(minutes: 31));
    manager.createJob(volumeTitle: 'fresh');
    expect(manager.jobCount, 1, reason: '过期半截任务出表');
    expect(job.dir.existsSync(), isFalse, reason: '目录一并删除');
  });

  group('shared volume dir', () {
    late DateTime now;
    late Directory jobRoot;

    setUp(() {
      now = DateTime(2026, 11, 10, 12);
      jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
    });

    MangaOcrHostJobManager buildManager(_ScriptedOcrService service) {
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: service,
        jobRoot: jobRoot,
        now: () => now,
      );
      addTearDown(() async {
        await manager.disposeAll();
        await service.closeAll();
      });
      return manager;
    }

    /// 建一个同卷 `T` 的任务、上传 1 页、start，等它进 error。
    Future<MangaOcrHostJob> failedJob(MangaOcrHostJobManager manager) async {
      final MangaOcrHostJob job = manager.createJob(volumeTitle: 'T');
      await manager.uploadPage(job, name: 'p1.png', bytes: <int>[1]);
      expect(await manager.start(job), isNull);
      await _waitState(job, MangaOcrHostJobState.error);
      return job;
    }

    test('TTL of an old job does not delete the dir a new job uses', () async {
      final _ScriptedOcrService service = _ScriptedOcrService(<bool>[
        true,
        false,
      ]);
      final MangaOcrHostJobManager manager = buildManager(service);
      final MangaOcrHostJob a = await failedJob(manager);

      now = now.add(const Duration(minutes: 30));
      final MangaOcrHostJob b = manager.createJob(volumeTitle: 'T');
      expect(p.canonicalize(b.dir.path), p.canonicalize(a.dir.path));
      await manager.uploadPage(b, name: 'p2.png', bytes: <int>[2]);
      expect(await manager.start(b), isNull);
      await _waitState(b, MangaOcrHostJobState.running);

      // A 超过 1h TTL；触达 housekeep。
      now = now.add(const Duration(minutes: 31));
      expect(manager.job(b.id), same(b));
      expect(manager.job(a.id), isNull, reason: '过期旧任务出表');
      expect(b.dir.existsSync(), isTrue, reason: '共享目录归仍在表里的 B');
      expect(File(p.join(b.dir.path, 'p2.png')).existsSync(), isTrue);
    });

    test(
      'cancelling an old job keeps pages of a live job in the same dir',
      () async {
        final _ScriptedOcrService service = _ScriptedOcrService(<bool>[true]);
        final MangaOcrHostJobManager manager = buildManager(service);
        final MangaOcrHostJob a = await failedJob(manager);

        final MangaOcrHostJob b = manager.createJob(volumeTitle: 'T');
        expect(p.canonicalize(b.dir.path), p.canonicalize(a.dir.path));
        await manager.uploadPage(b, name: 'p2.png', bytes: <int>[2]);
        final MangaOcrHostJobState before = b.state;

        await manager.cancelAndCleanup(a);
        expect(File(p.join(b.dir.path, 'p2.png')).existsSync(), isTrue);
        expect(b.state, before);
        expect(manager.job(b.id), same(b));
      },
    );

    test('cancelling with only terminal sharers still deletes pages', () async {
      final _ScriptedOcrService service = _ScriptedOcrService(<bool>[
        true,
        true,
      ]);
      final MangaOcrHostJobManager manager = buildManager(service);
      final MangaOcrHostJob a = await failedJob(manager);
      final MangaOcrHostJob b = manager.createJob(volumeTitle: 'T');
      expect(p.canonicalize(b.dir.path), p.canonicalize(a.dir.path));
      await manager.uploadPage(b, name: 'p2.png', bytes: <int>[2]);
      expect(await manager.start(b), isNull);
      await _waitState(b, MangaOcrHostJobState.error);
      final Directory out = Directory(p.join(b.dir.path, kMangaOcrOutDirName))
        ..createSync(recursive: true);

      await manager.cancelAndCleanup(b);
      expect(File(p.join(b.dir.path, 'p2.png')).existsSync(), isFalse);
      expect(out.existsSync(), isTrue, reason: '断点缓存保留');
      expect(manager.job(a.id), same(a));
    });
  });
}
