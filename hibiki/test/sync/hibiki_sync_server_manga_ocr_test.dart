/// 漫画 P3：互联 host 代跑 OCR 的 server 端点 + 任务管理器测试。
///
/// host 端 [MangaOcrService] 注入 fake（不下载模型、不跑真 ORT）：
/// - 全流程：创建 → 逐页上传 → start → 轮询 → result；
/// - 未鉴权 401 / 未接线 404 / capabilities 能力协商；
/// - 模型未就绪 503 models_not_ready；
/// - 上传页名穿越拒绝；
/// - 串行单并发队列（第二个 job 排队等第一个跑完）;
/// - 取消清理：页图删除、`manga_ocr_out/` 断点缓存保留（同卷重传后续传）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/sync/hibiki_manga_ocr_host.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

/// Fake host OCR 服务：按上传目录枚举页图，写 `manga_ocr_out/manga.json`。
/// [gate] 非 null 时在 finished 前等待（测串行队列/取消）。
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
        final Directory outDir =
            Directory(p.join(imageDirPath, kMangaOcrOutDirName))
              ..createSync(recursive: true);
        final File out = File(p.join(outDir.path, kMangaOcrOutputFileName));
        out.writeAsStringSync(jsonEncode(<String, Object?>{
          'pages': <Object?>[
            for (final String url in pages)
              <String, Object?>{
                'url': url,
                'width': 100,
                'height': 200,
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

Future<HttpClientResponse> _request(
  int port,
  String method,
  String path, {
  String? token,
  Object? jsonBody,
  List<int>? bodyBytes,
}) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest r =
      await c.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
  if (token != null) {
    r.headers.set(
        'authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
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

  HibikiSyncServer buildServer(_FakeOcrService service,
      {MangaOcrHostJobManager? manager}) {
    return HibikiSyncServer(
      syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
      port: 0,
      token: 'tok',
      mangaOcrJobs: manager ??
          MangaOcrHostJobManager(
            service: service,
            jobRoot: Directory(p.join(tmpRoot.path, 'jobs')),
          ),
    );
  }

  test('full flow: create → upload → start → poll → result', () async {
    final _FakeOcrService service = _FakeOcrService();
    final HibikiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);

    // 创建任务。
    final HttpClientResponse createResp = await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok',
        jsonBody: <String, Object?>{'volumeTitle': '卷一', 'pageCount': 2});
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
        bodyBytes: <int>[1, 2, 3]);
    expect(up1.statusCode, 200);
    final HttpClientResponse up2 = await _request(
        server.port,
        'PUT',
        '/api/ocr/job/$jobId/page/1'
            '?name=${Uri.encodeQueryComponent('sub/p002.jpg')}',
        token: 'tok',
        bodyBytes: <int>[4, 5, 6]);
    expect(up2.statusCode, 200);

    // 上传阶段状态。
    Map<String, dynamic> status = await _json(await _request(
        server.port, 'GET', '/api/ocr/job/$jobId',
        token: 'tok'));
    expect(status['state'], 'uploading');
    expect(status['pagesUploaded'], 2);

    // result 在完成前是 409 not_done。
    final HttpClientResponse early = await _request(
        server.port, 'GET', '/api/ocr/job/$jobId/result',
        token: 'tok');
    expect(early.statusCode, 409);

    // start → 轮询到 done。
    final HttpClientResponse startResp = await _request(
        server.port, 'POST', '/api/ocr/job/$jobId/start',
        token: 'tok');
    expect(startResp.statusCode, 200);
    for (int i = 0; i < 100; i++) {
      status = await _json(await _request(
          server.port, 'GET', '/api/ocr/job/$jobId',
          token: 'tok'));
      if (status['state'] == 'done') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status['state'], 'done');
    expect(status['pagesTotal'], 2);
    expect(service.lastVolumeTitle, '卷一');

    // result：manga.json 内容（页 url 保留相对子目录、自然序）。
    final HttpClientResponse resultResp = await _request(
        server.port, 'GET', '/api/ocr/job/$jobId/result',
        token: 'tok');
    expect(resultResp.statusCode, 200);
    final Map<String, dynamic> manga = await _json(resultResp);
    final List<dynamic> pages = manga['pages'] as List<dynamic>;
    expect(pages, hasLength(2));
    expect((pages[0] as Map<String, dynamic>)['url'], 'p001.jpg');
    expect((pages[1] as Map<String, dynamic>)['url'], 'sub/p002.jpg');
  });

  test('unauthenticated /api/ocr/* is 401', () async {
    final HibikiSyncServer server = buildServer(_FakeOcrService());
    await server.start();
    addTearDown(server.stop);
    final HttpClientResponse resp = await _request(
        server.port, 'POST', '/api/ocr/job',
        jsonBody: const <String, Object?>{});
    expect(resp.statusCode, 401);
  });

  test('endpoints are 404 and capabilities has no mangaOcr when not wired',
      () async {
    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: Directory(p.join(tmpRoot.path, 'sync')).path,
      port: 0,
      token: 'tok',
    );
    await server.start();
    addTearDown(server.stop);
    final HttpClientResponse resp = await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok', jsonBody: const <String, Object?>{});
    expect(resp.statusCode, 404);
    final Map<String, dynamic> caps = await _json(
        await _request(server.port, 'GET', '/api/capabilities', token: 'tok'));
    expect(caps.containsKey('mangaOcr'), isFalse);
  });

  test('capabilities reports mangaOcr supported/modelsReady', () async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    final HibikiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);
    Map<String, dynamic> caps = await _json(
        await _request(server.port, 'GET', '/api/capabilities', token: 'tok'));
    expect(caps['mangaOcr'], <String, Object?>{
      'supported': true,
      'modelsReady': false,
    });
    service.ready = true;
    caps = await _json(
        await _request(server.port, 'GET', '/api/capabilities', token: 'tok'));
    expect(caps['mangaOcr'], <String, Object?>{
      'supported': true,
      'modelsReady': true,
    });
  });

  test('start with models not ready → 503 models_not_ready', () async {
    final _FakeOcrService service = _FakeOcrService(ready: false);
    final HibikiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);
    final Map<String, dynamic> created = await _json(await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok', jsonBody: const <String, Object?>{}));
    final String jobId = created['jobId'] as String;
    await _request(server.port, 'PUT', '/api/ocr/job/$jobId/page/0?name=a.jpg',
        token: 'tok', bodyBytes: <int>[1]);
    final HttpClientResponse resp = await _request(
        server.port, 'POST', '/api/ocr/job/$jobId/start',
        token: 'tok');
    expect(resp.statusCode, 503);
    expect((await _json(resp))['error'], 'models_not_ready');
    expect(service.started, 0);
  });

  test('unsupported platform → 503 not_supported', () async {
    final _FakeOcrService service = _FakeOcrService(supported: false);
    final HibikiSyncServer server = buildServer(service);
    await server.start();
    addTearDown(server.stop);
    final Map<String, dynamic> created = await _json(await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok', jsonBody: const <String, Object?>{}));
    final String jobId = created['jobId'] as String;
    await _request(server.port, 'PUT', '/api/ocr/job/$jobId/page/0?name=a.jpg',
        token: 'tok', bodyBytes: <int>[1]);
    final HttpClientResponse resp = await _request(
        server.port, 'POST', '/api/ocr/job/$jobId/start',
        token: 'tok');
    expect(resp.statusCode, 503);
    expect((await _json(resp))['error'], 'not_supported');
  });

  test('page upload rejects traversal / absolute / reserved names', () async {
    final HibikiSyncServer server = buildServer(_FakeOcrService());
    await server.start();
    addTearDown(server.stop);
    final Map<String, dynamic> created = await _json(await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok', jsonBody: const <String, Object?>{}));
    final String jobId = created['jobId'] as String;
    for (final String bad in <String>[
      '../evil.jpg',
      'sub/../../evil.jpg',
      '/abs.jpg',
      'manga_ocr_out/poison.json',
      '',
    ]) {
      final HttpClientResponse resp = await _request(server.port, 'PUT',
          '/api/ocr/job/$jobId/page/0?name=${Uri.encodeQueryComponent(bad)}',
          token: 'tok', bodyBytes: <int>[1]);
      expect(resp.statusCode, 400, reason: 'name=$bad must be rejected');
    }
  });

  test('unknown job → 404 unknown_job', () async {
    final HibikiSyncServer server = buildServer(_FakeOcrService());
    await server.start();
    addTearDown(server.stop);
    final HttpClientResponse resp =
        await _request(server.port, 'GET', '/api/ocr/job/nope', token: 'tok');
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

  test('DELETE cancels at page boundary, keeps checkpoint cache for resume',
      () async {
    final _FakeOcrService service = _FakeOcrService()..gate = Completer<void>();
    final Directory jobRoot = Directory(p.join(tmpRoot.path, 'jobs'));
    final MangaOcrHostJobManager manager =
        MangaOcrHostJobManager(service: service, jobRoot: jobRoot);
    final HibikiSyncServer server = buildServer(service, manager: manager);
    await server.start();
    addTearDown(server.stop);

    final Map<String, dynamic> created = await _json(await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok', jsonBody: <String, Object?>{'volumeTitle': '同卷'}));
    final String jobId = created['jobId'] as String;
    await _request(
        server.port, 'PUT', '/api/ocr/job/$jobId/page/0?name=p001.jpg',
        token: 'tok', bodyBytes: <int>[1, 2, 3]);
    await _request(server.port, 'POST', '/api/ocr/job/$jobId/start',
        token: 'tok');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 任务目录：页图已落盘；模拟逐页断点缓存已写。
    final Directory jobDir = jobRoot.listSync().whereType<Directory>().single;
    expect(File(p.join(jobDir.path, 'p001.jpg')).existsSync(), isTrue);
    final File cacheFile = File(
        p.join(jobDir.path, kMangaOcrOutDirName, '_pages', 'p001.jpg.json'))
      ..createSync(recursive: true);

    final HttpClientResponse delResp = await _request(
        server.port, 'DELETE', '/api/ocr/job/$jobId',
        token: 'tok');
    expect(delResp.statusCode, 200);
    expect(service.lastCancelled, isTrue, reason: '订阅取消 = 页边界中止');
    // 页图删除、断点缓存保留。
    expect(File(p.join(jobDir.path, 'p001.jpg')).existsSync(), isFalse);
    expect(cacheFile.existsSync(), isTrue);
    expect(manager.jobCount, 0);
    // 任务已出表：再查 404。
    final HttpClientResponse gone =
        await _request(server.port, 'GET', '/api/ocr/job/$jobId', token: 'tok');
    expect(gone.statusCode, 404);
    // 放行 fake 的挂起循环，避免泄漏 pending timer。
    service.gate?.complete();
    service.gate = null;

    // 同卷新任务落回同一目录 → 断点缓存可续传。
    final Map<String, dynamic> again = await _json(await _request(
        server.port, 'POST', '/api/ocr/job',
        token: 'tok', jsonBody: <String, Object?>{'volumeTitle': '同卷'}));
    expect(again['jobId'], isNot(jobId));
    final Directory jobDir2 = jobRoot.listSync().whereType<Directory>().single;
    expect(p.canonicalize(jobDir2.path), p.canonicalize(jobDir.path));

    // 取消不得卡死串行队列（cancelAndCleanup 补完成信号的回归守卫）：
    // 重传后 start 新任务必须能跑完。
    final String jobId2 = again['jobId'] as String;
    await _request(
        server.port, 'PUT', '/api/ocr/job/$jobId2/page/0?name=p001.jpg',
        token: 'tok', bodyBytes: <int>[1, 2, 3]);
    await _request(server.port, 'POST', '/api/ocr/job/$jobId2/start',
        token: 'tok');
    Map<String, dynamic> status = const <String, dynamic>{};
    for (int i = 0; i < 100; i++) {
      status = await _json(await _request(
          server.port, 'GET', '/api/ocr/job/$jobId2',
          token: 'tok'));
      if (status['state'] == 'done') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status['state'], 'done', reason: '取消后队列必须继续放行新任务');
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
}
