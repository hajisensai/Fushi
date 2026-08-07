import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

/// 互联传输层性能守卫（BUG-937 / 提速批次）：
///
/// 1. 封面端点必须走单行直查（[FushiLibraryHostService.videoCoverPath] /
///    [FushiLibraryHostService.bookCoverPath]），**绝不** materialize 整份
///    listVideos()/listBooks() 清单——旧实现每张封面重跑全量清单（每行一次目录
///    扫描 + 多次 DB 查询），N 张封面 = O(N²)，500 视频的封面墙浏览一次拖成分钟
///    级（「互联视频极慢」的主根因）。fake 的 list* 直接抛错，端点仍须 200。
/// 2. JSON 清单响应按 `Accept-Encoding: gzip` 内容协商压缩；不带该头的旧 client
///    收到原样明文（零协议破坏）。文件流（封面/视频，含 Range/206）不压——
///    `Content-Encoding` 会与断点续传/libmpv 的字节账语义交叉。
class _CoverGuardService implements FushiLibraryHostService {
  _CoverGuardService(this.videoCover, this.bookCover);

  final File videoCover;
  final File bookCover;
  int videoCoverPathCalls = 0;
  int bookCoverPathCalls = 0;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async =>
      throw StateError('cover endpoint must not materialize listVideos()');

  @override
  Future<List<RemoteBookInfo>> listBooks() async =>
      throw StateError('cover endpoint must not materialize listBooks()');

  @override
  Future<String?> videoCoverPath(String id) async {
    videoCoverPathCalls++;
    return id == 'video/known' ? videoCover.path : null;
  }

  @override
  Future<String?> bookCoverPath(String id) async {
    bookCoverPathCalls++;
    return id == 'book-key' ? bookCover.path : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

/// gzip 协商测试用：清单返回固定条目（listVideos 可用），封面单查可用。
class _GzipListService implements FushiLibraryHostService {
  _GzipListService(this.cover);

  final File cover;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/a',
          title: ''.padRight(512, 'A'), // 足够长，确保 gzip 真正生效
          sizeBytes: 1,
          hasSubtitle: false,
          hasCover: true,
          coverPath: cover.path,
        ),
      ];

  @override
  Future<String?> videoCoverPath(String id) async =>
      id == 'video/a' ? cover.path : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

void main() {
  const String token = 'perf-guard-token';
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hbk_perf_guard');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('封面端点单行直查守卫', () {
    late FushiSyncServer server;
    late _CoverGuardService lib;
    late String base;

    setUp(() async {
      final File videoCover = File(p.join(tmp.path, 'v.jpg'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final File bookCover = File(p.join(tmp.path, 'b.jpg'))
        ..writeAsBytesSync(<int>[5, 6, 7]);
      lib = _CoverGuardService(videoCover, bookCover);
      server = FushiSyncServer(
        syncDataDir: p.join(tmp.path, 'sync1'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: lib,
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
    });

    test('视频封面 200 且不 materialize listVideos()', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c
          .getUrl(Uri.parse('$base/api/library/videos/video%2Fknown/cover'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      final List<int> body = <int>[
        for (final List<int> chunk in await res.toList()) ...chunk,
      ];
      expect(res.statusCode, 200);
      expect(body, <int>[1, 2, 3, 4]);
      expect(lib.videoCoverPathCalls, 1);
      c.close(force: true);
    });

    test('书封面 200 且不 materialize listBooks()', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$base/api/library/books/book-key/cover'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      final List<int> body = <int>[
        for (final List<int> chunk in await res.toList()) ...chunk,
      ];
      expect(res.statusCode, 200);
      expect(body, <int>[5, 6, 7]);
      expect(lib.bookCoverPathCalls, 1);
      c.close(force: true);
    });

    test('未知 id 404（单查返回 null）', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c
          .getUrl(Uri.parse('$base/api/library/videos/video%2Fnope/cover'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 404);
      c.close(force: true);
    });
  });

  group('JSON gzip 内容协商', () {
    late FushiSyncServer server;
    late File cover;

    setUp(() async {
      cover = File(p.join(tmp.path, 'gz.jpg'))
        ..writeAsBytesSync(List<int>.filled(64, 9));
      server = FushiSyncServer(
        syncDataDir: p.join(tmp.path, 'sync2'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _GzipListService(cover),
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    /// 原始 socket 级请求：dart HttpClient 会自动解压并隐藏 Content-Encoding，
    /// 这里要断言的恰是线上的字节形态，必须绕开它。
    Future<({int status, Map<String, String> headers, List<int> body})> rawGet(
        String path,
        {String? acceptEncoding}) async {
      final Socket socket = await Socket.connect('127.0.0.1', server.port);
      final StringBuffer req = StringBuffer()
        ..write('GET $path HTTP/1.1\r\n')
        ..write('Host: 127.0.0.1\r\n')
        ..write('Authorization: ${authHeader()}\r\n');
      if (acceptEncoding != null) {
        req.write('Accept-Encoding: $acceptEncoding\r\n');
      }
      req.write('Connection: close\r\n\r\n');
      socket.write(req.toString());
      await socket.flush();
      final List<int> raw = <int>[
        for (final List<int> chunk in await socket.toList()) ...chunk,
      ];
      socket.destroy();
      // 头/体以 \r\n\r\n 分界。
      int split = -1;
      for (int i = 0; i + 3 < raw.length; i++) {
        if (raw[i] == 13 &&
            raw[i + 1] == 10 &&
            raw[i + 2] == 13 &&
            raw[i + 3] == 10) {
          split = i;
          break;
        }
      }
      expect(split, greaterThan(0), reason: '响应必须有头/体分界');
      final List<String> headLines =
          utf8.decode(raw.sublist(0, split)).split('\r\n');
      final int status = int.parse(headLines.first.split(' ')[1]);
      final Map<String, String> headers = <String, String>{};
      for (final String line in headLines.skip(1)) {
        final int colon = line.indexOf(':');
        if (colon <= 0) continue;
        headers[line.substring(0, colon).trim().toLowerCase()] =
            line.substring(colon + 1).trim();
      }
      List<int> body = raw.sublist(split + 4);
      if (headers['transfer-encoding'] == 'chunked') {
        body = _dechunk(body);
      }
      return (status: status, headers: headers, body: body);
    }

    test('带 Accept-Encoding: gzip → 清单 gzip 压缩且可解回', () async {
      final ({int status, Map<String, String> headers, List<int> body}) res =
          await rawGet('/api/library/videos', acceptEncoding: 'gzip');
      expect(res.status, 200);
      expect(res.headers['content-encoding'], 'gzip');
      final String json = utf8.decode(gzip.decode(res.body));
      expect(json, contains('video/a'));
    });

    test('不带 Accept-Encoding → 原样明文（旧 client 兼容）', () async {
      final ({int status, Map<String, String> headers, List<int> body}) res =
          await rawGet('/api/library/videos');
      expect(res.status, 200);
      expect(res.headers.containsKey('content-encoding'), isFalse);
      expect(utf8.decode(res.body), contains('video/a'));
    });

    test('封面文件流即使带 Accept-Encoding 也不压（Range/断点续传语义）', () async {
      final ({int status, Map<String, String> headers, List<int> body}) res =
          await rawGet('/api/library/videos/video%2Fa/cover',
              acceptEncoding: 'gzip');
      expect(res.status, 200);
      expect(res.headers.containsKey('content-encoding'), isFalse);
      expect(res.body, List<int>.filled(64, 9));
    });
  });
}

/// 解 HTTP/1.1 chunked 编码（测试内最小实现）。
List<int> _dechunk(List<int> body) {
  final List<int> out = <int>[];
  int i = 0;
  while (i < body.length) {
    int lineEnd = i;
    while (lineEnd + 1 < body.length &&
        !(body[lineEnd] == 13 && body[lineEnd + 1] == 10)) {
      lineEnd++;
    }
    final String sizeHex =
        String.fromCharCodes(body.sublist(i, lineEnd)).split(';').first.trim();
    final int size = int.parse(sizeHex, radix: 16);
    if (size == 0) break;
    final int dataStart = lineEnd + 2;
    out.addAll(body.sublist(dataStart, dataStart + size));
    i = dataStart + size + 2; // 跳过数据后的 \r\n
  }
  return out;
}
