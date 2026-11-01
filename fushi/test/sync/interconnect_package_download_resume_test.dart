import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_package_download.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/repr_digest.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:path/path.dart' as p;

/// 反馈 Sn4fYseBt4：互联大文件（本地音频库等）断点续传 + 整体校验 + 后台 isolate 收包。
///
/// 1. host 导出缓存是**滑动** TTL：正在被使用的那份字节不会因为「导出满 15 分钟」
///    换代（旧实现按导出时刻算，长传输一断续传必然从 0 重来）。
/// 2. 包响应带整份表示的 `Repr-Digest`（200 / 206 都带），值就是缓存文件的 SHA-256。
/// 3. 一次下载调用内断流：只要真有新字节进来就从断点接着拉，拼完按 Repr-Digest 校验。
/// 4. 零进展的断流不接续（不是盲目重试）；`.part` 保留供下一轮。
/// 5. 响应声明的总长 / 摘要对不上：短了保留 `.part` 可续，摘要不符丢弃。
/// 6. 后台 isolate 下载端到端（真 host + 中途断流）。
class _PkgService implements FushiLibraryHostService {
  _PkgService(this.payload);

  final List<int> payload;
  int exportCalls = 0;

  @override
  Future<File> exportDictionary(String name) async {
    if (name != 'JMdict') throw StateError('dictionary not found');
    exportCalls++;
    final Directory tmp = Directory.systemTemp.createTempSync('pkg_exp');
    final File f = File(p.join(tmp.path, '$name.fushidict'));
    f.writeAsBytesSync(payload);
    return f;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

List<int> _payload(int n) => <int>[for (int i = 0; i < n; i++) (i * 31) & 0xff];

/// 发 [body]（尊重 `Range: bytes=N-`）；[cutAfter] 非空时只发前这么多字节就让流报错
/// （模拟连接中途被关）。
ResumableDownloadResponse _respond(
  List<int> body,
  Map<String, String> headers, {
  int? cutAfter,
  bool withDigest = true,
  List<int>? digestOverride,
}) {
  int start = 0;
  final String? range = headers[HttpHeaders.rangeHeader];
  if (range != null) {
    start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
  }
  final List<int> slice = body.sublist(start);
  final StreamController<List<int>> c = StreamController<List<int>>();
  if (cutAfter != null) {
    c.add(slice.sublist(0, cutAfter));
    c.addError(const HttpException('Connection closed while receiving data'));
  } else {
    c.add(slice);
  }
  c.close();
  final List<int> digest = digestOverride ?? sha256.convert(body).bytes;
  return ResumableDownloadResponse(
    statusCode: start > 0 ? 206 : 200,
    headers: <String, String>{
      'etag': '"pkg-1"',
      'content-length': '${slice.length}',
      if (start > 0)
        'content-range': 'bytes $start-${body.length - 1}/${body.length}',
      if (withDigest) kReprDigestHeader: formatReprDigestSha256(digest),
    },
    stream: c.stream,
  );
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ic_resume'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ExportPackageCache 滑动 TTL + Repr-Digest', () {
    test('使用中续期：导出满 TTL 但一直在用 → 不换代；闲置满 TTL 才换代', () async {
      final ExportPackageCache cache = ExportPackageCache(
        ttl: const Duration(milliseconds: 400),
      );
      addTearDown(cache.dispose);
      int gen = 0;
      Future<File> export() async {
        gen++;
        final Directory tmp = Directory.systemTemp.createTempSync('pkg_slide');
        final File f = File(p.join(tmp.path, 'x.bin'));
        f.writeAsBytesSync(List<int>.filled(16, gen));
        return f;
      }

      final File a = await cache.obtain('dict', 'x', export);
      // 模拟一次长传输：持续 600ms（> TTL），期间每 100ms 有字节发出。
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        cache.markUsed('dict', 'x');
      }
      final File b = await cache.obtain('dict', 'x', export);
      expect(gen, 1, reason: '一直在用的字节不得因「导出满 TTL」换代——续传会被迫从 0 重来');
      expect(b.path, a.path);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      await cache.obtain('dict', 'x', export);
      expect(gen, 2, reason: '闲置满 TTL 后照常重导出');
    });

    test('包响应 200 / 206 都带整份 Repr-Digest，值等于字节的 SHA-256', () async {
      final List<int> payload = _payload(5000);
      final _PkgService lib = _PkgService(payload);
      const String token = 'tok';
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: dir.path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: lib,
      );
      await server.start();
      addTearDown(server.stop);
      final HttpClient c = HttpClient();
      addTearDown(() => c.close(force: true));
      final String auth = 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';
      final Uri uri = Uri.parse(
        'http://127.0.0.1:${server.port}/api/library/dictionaries/JMdict',
      );

      final HttpClientRequest r1 = await c.getUrl(uri);
      r1.headers.set('authorization', auth);
      final HttpClientResponse res1 = await r1.close();
      final List<int> body1 = <int>[
        for (final List<int> chunk in await res1.toList()) ...chunk,
      ];
      expect(res1.statusCode, 200);
      expect(body1, payload);
      final List<int>? d1 = parseReprDigestSha256(
        res1.headers.value(kReprDigestHeader),
      );
      expect(d1, sha256.convert(payload).bytes);

      final HttpClientRequest r2 = await c.getUrl(uri);
      r2.headers.set('authorization', auth);
      r2.headers.set('range', 'bytes=100-');
      r2.headers.set('if-range', res1.headers.value('etag')!);
      final HttpClientResponse res2 = await r2.close();
      await res2.drain<void>();
      expect(res2.statusCode, 206);
      expect(
        parseReprDigestSha256(res2.headers.value(kReprDigestHeader)),
        d1,
        reason: 'Repr-Digest 描述整份表示，206 片段也带同一个值',
      );
      expect(lib.exportCalls, 1);
    });
  });

  group('downloadWithResumeSidecar', () {
    test('断流且有进展 → 本次调用内从断点接着拉，拼完校验通过', () async {
      final List<int> body = _payload(10000);
      final File dest = File(p.join(dir.path, 'a.bin'));
      final List<Map<String, String>> requests = <Map<String, String>>[];
      await downloadWithResumeSidecar(
        url: 'http://host/x',
        destination: dest,
        firstByteTimeout: const Duration(seconds: 5),
        stallTimeout: const Duration(seconds: 5),
        verifyResponseIntegrity: true,
        open: (Uri uri, Map<String, String> headers) async {
          requests.add(Map<String, String>.of(headers));
          return _respond(
            body,
            headers,
            cutAfter: requests.length == 1 ? 3000 : null,
          );
        },
      );
      expect(dest.readAsBytesSync(), body);
      expect(requests, hasLength(2));
      expect(requests[1][HttpHeaders.rangeHeader], 'bytes=3000-');
      expect(requests[1][HttpHeaders.ifRangeHeader], '"pkg-1"');
      expect(File('${dest.path}.part').existsSync(), isFalse);
      expect(File('${dest.path}.part.etag').existsSync(), isFalse);
    });

    test('零进展的断流不接续：错误交给调用方，已有 .part 与侧车保留供下一轮', () async {
      final List<int> body = _payload(4000);
      final File dest = File(p.join(dir.path, 'b.bin'));
      int opens = 0;
      Future<void> run({required int? cut}) => downloadWithResumeSidecar(
        url: 'http://host/x',
        destination: dest,
        firstByteTimeout: const Duration(seconds: 5),
        stallTimeout: const Duration(seconds: 5),
        verifyResponseIntegrity: true,
        open: (Uri uri, Map<String, String> headers) async {
          opens++;
          final bool resumed = headers.containsKey(HttpHeaders.rangeHeader);
          return _respond(body, headers, cutAfter: resumed ? 0 : cut);
        },
      );
      await expectLater(run(cut: 1500), throwsA(isA<HttpException>()));
      expect(opens, 2, reason: '首次有进展 → 接续一次；接续零进展 → 停');
      expect(File('${dest.path}.part').lengthSync(), 1500);
      expect(File('${dest.path}.part.etag').existsSync(), isTrue);

      // 下一轮（另一次调用、同一目标路径）从 1500 续上并完成。
      opens = 0;
      await downloadWithResumeSidecar(
        url: 'http://host/x',
        destination: dest,
        firstByteTimeout: const Duration(seconds: 5),
        stallTimeout: const Duration(seconds: 5),
        verifyResponseIntegrity: true,
        open: (Uri uri, Map<String, String> headers) async {
          opens++;
          expect(headers[HttpHeaders.rangeHeader], 'bytes=1500-');
          return _respond(body, headers);
        },
      );
      expect(opens, 1);
      expect(dest.readAsBytesSync(), body);
    });

    test('Repr-Digest 不符 → 丢弃 .part 抛完整性异常（不把坏包交给导入）', () async {
      final List<int> body = _payload(2000);
      final File dest = File(p.join(dir.path, 'c.bin'));
      await expectLater(
        downloadWithResumeSidecar(
          url: 'http://host/x',
          destination: dest,
          firstByteTimeout: const Duration(seconds: 5),
          stallTimeout: const Duration(seconds: 5),
          verifyResponseIntegrity: true,
          open: (Uri uri, Map<String, String> headers) async =>
              _respond(body, headers, digestOverride: List<int>.filled(32, 7)),
        ),
        throwsA(isA<ResumableDownloadIntegrityException>()),
      );
      expect(dest.existsSync(), isFalse);
      expect(File('${dest.path}.part').existsSync(), isFalse);
    });

    test('流被干净地提前关掉（短于声明总长）→ 保留 .part 抛可续传的 HttpException', () async {
      final List<int> body = _payload(3000);
      final File dest = File(p.join(dir.path, 'd.bin'));
      await expectLater(
        downloadWithResumeSidecar(
          url: 'http://host/x',
          destination: dest,
          firstByteTimeout: const Duration(seconds: 5),
          stallTimeout: const Duration(seconds: 5),
          verifyResponseIntegrity: true,
          resumeInCall: false,
          open: (Uri uri, Map<String, String> headers) async =>
              ResumableDownloadResponse(
                statusCode: 200,
                headers: <String, String>{
                  'etag': '"pkg-1"',
                  'content-length': '${body.length}',
                },
                stream: Stream<List<int>>.value(body.sublist(0, 1000)),
              ),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(dest.existsSync(), isFalse, reason: '截断的包绝不能被提升为成品');
      expect(File('${dest.path}.part').lengthSync(), 1000);
    });

    test('gzip 响应（Content-Length 是编码后长度）不被误判为截断', () async {
      // host 的 _gzipTextMiddleware 压缩小 JSON：编码后反而比原文长，HttpClient
      // 自动解压后流里只有原文字节。旧实现把线上 Content-Length 当声明总长 → 误报截断。
      final List<int> body = utf8.encode('{"v":3,"profile":"p"}');
      final List<int> wire = gzip.encode(body);
      expect(wire.length, greaterThan(body.length));
      final HttpServer srv = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => srv.close(force: true));
      srv.listen((HttpRequest req) async {
        req.response.headers
          ..set(HttpHeaders.contentEncodingHeader, 'gzip')
          ..set(HttpHeaders.etagHeader, '"meta-1"')
          ..contentLength = wire.length;
        req.response.add(wire);
        await req.response.close();
      });
      final HttpClient client = HttpClient();
      addTearDown(() => client.close(force: true));
      final File dest = File(p.join(dir.path, 'meta.json'));
      await downloadWithResumeSidecar(
        url: 'http://127.0.0.1:${srv.port}/meta.json',
        destination: dest,
        firstByteTimeout: const Duration(seconds: 5),
        stallTimeout: const Duration(seconds: 5),
        verifyResponseIntegrity: true,
        resumeInCall: false,
        open: (Uri uri, Map<String, String> headers) async {
          final HttpClientRequest req = await client.getUrl(uri);
          headers.forEach(req.headers.set);
          return wrapResumableResponse(await req.close());
        },
      );
      expect(dest.readAsBytesSync(), body);
    });
  });

  group('后台 isolate 下载（真 HTTP）', () {
    test('中途断流 → isolate 内从断点接着拉，成品与 host 字节一致', () async {
      final List<int> body = _payload(200000);
      final String digest = formatReprDigestSha256(sha256.convert(body).bytes);
      int requests = 0;
      final List<String?> ranges = <String?>[];
      final HttpServer srv = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => srv.close(force: true));
      srv.listen((HttpRequest req) async {
        requests++;
        final String? range = req.headers.value('range');
        ranges.add(range);
        int start = 0;
        if (range != null) {
          start = int.parse(
            RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
          );
        }
        final HttpResponse res = req.response;
        res.statusCode = start > 0 ? 206 : 200;
        res.headers.set('etag', '"pkg-iso"');
        res.headers.set(kReprDigestHeader, digest);
        res.contentLength = body.length - start;
        if (start > 0) {
          res.headers.set(
            'content-range',
            'bytes $start-${body.length - 1}/${body.length}',
          );
        }
        if (requests == 1) {
          // 发一半就把底层连接掐掉（模拟 Wi-Fi 抖动 / 对端断开）。
          final Socket s = await res.detachSocket();
          s.add(body.sublist(0, 80000));
          await s.flush();
          s.destroy();
          return;
        }
        res.add(body.sublist(start));
        await res.close();
      });

      final File dest = File(p.join(dir.path, 'iso.bin'));
      final List<int> seen = <int>[];
      await runPinnedPackageDownloadInIsolate(
        PinnedPackageDownloadSpec(
          url: 'http://127.0.0.1:${srv.port}/api/library/localaudio/x',
          destinationPath: dest.path,
          baseUrl: 'http://127.0.0.1:${srv.port}',
          token: 'tok',
          pinnedFingerprint: null,
          connectionTimeout: const Duration(seconds: 5),
          firstByteTimeout: const Duration(seconds: 10),
          stallTimeout: const Duration(seconds: 10),
        ),
        onProgress: (int received, int? total) => seen.add(received),
      );
      expect(dest.readAsBytesSync(), body);
      expect(requests, 2);
      expect(ranges.last, isNotNull, reason: '第二次请求必须是带 Range 的续传，而不是从 0 重下');
      expect(seen, isNotEmpty);
      expect(seen.last, body.length);
    });
  });
}
