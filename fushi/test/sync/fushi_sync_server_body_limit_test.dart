/// BUG（interconnect-unbounded-request-body）：互联 host 读请求体必须有上限。
///
/// 真 server（loopback）+ 原始 socket 手发请求：免鉴权配对端点超 16 KiB 回 413
/// 且不建会话；声明巨大 Content-Length 却只发一点正文的慢速请求立即 413，不挂起
/// 等体；已鉴权的正常小体不受影响。另覆盖 host 任务 / 漫画 OCR 两条路由的读体上限。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_routes.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 手写一条 HTTP/1.1 请求：发完头和 [body]（不足声明长度时**不关**写端），
/// 读到响应状态行即返回状态码。服务端在挂起等体时，这里会超时。
Future<int> _rawRequest(
  int port,
  String method,
  String path, {
  required List<int> body,
  int? declaredLength,
  Map<String, String> headers = const <String, String>{},
}) async {
  final Socket socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
  );
  final Completer<int> status = Completer<int>();
  final BytesBuilder received = BytesBuilder();
  socket.listen(
    (Uint8List data) {
      received.add(data);
      final String text = latin1.decode(received.toBytes());
      final RegExpMatch? m = RegExp(r'^HTTP/1\.1 (\d{3})').firstMatch(text);
      if (m != null && !status.isCompleted) {
        status.complete(int.parse(m.group(1)!));
      }
    },
    onError: (Object _) {},
    onDone: () {
      if (!status.isCompleted) status.completeError('closed without status');
    },
    cancelOnError: false,
  );
  final StringBuffer head = StringBuffer()
    ..write('$method $path HTTP/1.1\r\n')
    ..write('Host: 127.0.0.1:$port\r\n')
    ..write('Content-Type: application/json\r\n')
    ..write('Content-Length: ${declaredLength ?? body.length}\r\n');
  headers.forEach((String k, String v) => head.write('$k: $v\r\n'));
  head.write('\r\n');
  socket.add(latin1.encode(head.toString()));
  socket.add(body);
  try {
    await socket.flush();
  } on Object {
    // 服务端已回 413 并断开：写端报错不影响读状态码。
  }
  try {
    return await status.future.timeout(const Duration(seconds: 5));
  } finally {
    socket.destroy();
  }
}

String _basic(String token) => 'Basic ${base64Encode(utf8.encode('x:$token'))}';

class _ProgressHost implements FushiLibraryHostService {
  final List<RemoteBookProgress> puts = <RemoteBookProgress>[];

  @override
  Future<void> putBookProgress(String bookKey, RemoteBookProgress p) async {
    puts.add(p);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EchoRunner implements HostJobRunner {
  @override
  String get kind => 'echo';

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'ready': true,
  };

  @override
  void validateParams(Map<String, Object?> params) {}

  @override
  String contentTypeFor(String outputName) => 'text/plain';

  @override
  Future<HostJobOutcome> run(HostJobContext ctx) async =>
      const HostJobOutcome(outputs: <String, String>{});
}

class _NoOcrService implements MangaOcrService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  late FushiSyncServer server;
  int pairRequests = 0;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_body_limit_test');
    pairRequests = 0;
  });

  tearDown(() async {
    await server.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> startServer({FushiLibraryHostService? library}) async {
    server =
        FushiSyncServer(
            syncDataDir: tmp.path,
            port: 0,
            token: 'tok',
            allowLan: true,
            libraryService: library,
          )
          ..onPairRequest = ((FushiPairRequest _) async {
            pairRequests++;
            return true;
          })
          ..onPairPinGenerated = ((FushiPairSession s) => '000000')
          ..lanRequiresPinProvider = (() async => false);
    await server.start();
  }

  test('免鉴权 pair/v2 发 64 KiB 合法 JSON → 413，不建会话', () async {
    await startServer();
    final List<int> body = utf8.encode(
      jsonEncode(<String, String>{
        'clientNonce': 'cn-big',
        'name': 'x' * (64 * 1024),
      }),
    );
    final int code = await _rawRequest(
      server.port,
      'POST',
      '/api/pair/v2',
      body: body,
    );
    expect(code, 413);
    expect(pairRequests, 0);
    expect(server.pendingPairSessionCount, 0);
  });

  test('pair/v2 声明 100 MB 只发 1 KiB：5 秒内 413，不挂起等体', () async {
    await startServer();
    final int code = await _rawRequest(
      server.port,
      'POST',
      '/api/pair/v2',
      body: List<int>.filled(1024, 0x20),
      declaredLength: 100000000,
    );
    expect(code, 413);
    expect(pairRequests, 0);
    expect(server.pendingPairSessionCount, 0);
  });

  test('已鉴权 PUT 书进度 2 KiB 合法体仍 200（不误伤）', () async {
    final _ProgressHost host = _ProgressHost();
    await startServer(library: host);
    final List<int> body = utf8.encode(
      jsonEncode(<String, Object?>{'chapterIndex': 1, 'pad': 'y' * 2048}),
    );
    final int code = await _rawRequest(
      server.port,
      'PUT',
      '/api/library/books/book-1/progress',
      body: body,
      headers: <String, String>{'Authorization': _basic('tok')},
    );
    expect(code, 200);
    expect(host.puts, hasLength(1));
  });

  group('host 任务 / 漫画 OCR 路由的读体上限', () {
    setUp(() async {
      // 这组不用网络 server；给 tearDown 一个可停的实例。
      await startServer();
    });

    shelf.Handler jobsHandler(HostJobManager jobs) => bodyLimitMiddleware()(
      (shelf.Request r) => handleHostJobRequest(
        jobs,
        r,
        r.method,
        Uri.decodeFull('/${r.url.path}'),
      ),
    );

    test('POST /api/jobs 超 64 KiB → 413，不建任务', () async {
      final HostJobManager jobs = HostJobManager(
        jobRoot: Directory(p.join(tmp.path, 'jobs')),
        runners: <HostJobRunner>[_EchoRunner()],
      );
      final shelf.Response res = await jobsHandler(jobs)(
        shelf.Request(
          'POST',
          Uri.parse('http://h/api/jobs'),
          body: jsonEncode(<String, Object?>{
            'kind': 'echo',
            'params': <String, String>{'pad': 'z' * (64 * 1024)},
          }),
          headers: const <String, String>{'Content-Type': 'application/json'},
        ),
      );
      expect(res.statusCode, 413);
      expect(jobs.list(), isEmpty);
    });

    test('POST /api/jobs/<id>/inputs/match 声明超限 → 413', () async {
      final HostJobManager jobs = HostJobManager(
        jobRoot: Directory(p.join(tmp.path, 'jobs')),
        runners: <HostJobRunner>[_EchoRunner()],
      );
      final shelf.Response res = await jobsHandler(jobs)(
        shelf.Request(
          'POST',
          Uri.parse('http://h/api/jobs/any/inputs/match'),
          body: Stream<List<int>>.value(utf8.encode('{}')),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Content-Length': '${kHostJobMatchBodyMaxBytes + 1}',
          },
        ),
      );
      expect(res.statusCode, 413);
    });

    shelf.Handler ocrHandler(MangaOcrHostJobManager m) => bodyLimitMiddleware()(
      (shelf.Request r) => handleMangaOcrRequest(
        m,
        r,
        r.method,
        Uri.decodeFull('/${r.url.path}'),
      ),
    );

    test('POST /api/ocr/job 超 64 KiB → 413，不建任务', () async {
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: _NoOcrService(),
        jobRoot: Directory(p.join(tmp.path, 'ocr')),
      );
      final shelf.Response res = await ocrHandler(manager)(
        shelf.Request(
          'POST',
          Uri.parse('http://h/api/ocr/job'),
          body: jsonEncode(<String, Object?>{'volumeTitle': 'v' * 70000}),
          headers: const <String, String>{'Content-Type': 'application/json'},
        ),
      );
      expect(res.statusCode, 413);
      expect(manager.jobCount, 0);
    });

    test('PUT 页图声明超 64 MiB → 413，不等正文', () async {
      final MangaOcrHostJobManager manager = MangaOcrHostJobManager(
        service: _NoOcrService(),
        jobRoot: Directory(p.join(tmp.path, 'ocr')),
      );
      final MangaOcrHostJob job = manager.createJob(volumeTitle: 'v');
      bool cancelled = false;
      bool pulled = false;
      final StreamController<List<int>> page = StreamController<List<int>>(
        onListen: () => pulled = true,
        onCancel: () => cancelled = true,
      );
      final shelf.Response res = await ocrHandler(manager)(
        shelf.Request(
          'PUT',
          Uri.parse('http://h/api/ocr/job/${job.id}/page/0?name=a.jpg'),
          body: page.stream,
          headers: <String, String>{
            'Content-Length': '${kMangaOcrPageBodyMaxBytes + 1}',
          },
        ),
      );
      expect(res.statusCode, 413);
      // 一块数据都没等、停在暂停（不取消，见 readBoundedRequestBody）；也没有落页。
      expect(pulled, isTrue);
      expect(page.isPaused, isTrue);
      expect(cancelled, isFalse);
      expect(job.pagesUploaded, 0);
    });
  });
}
