// TODO-1274 WebDAV 来源文件系统行为测试（无需真实 WebDAV 服务器）：
// 起一个进程内 HttpServer 冒充 WebDAV 端点，实答 PROPFIND（207 multistatus）+ GET，
// 验证 NetworkSourceFileSystem 的 WebDAV 分支真跑通：
//  1) listFiles(recursive) 递归解析 PROPFIND，只回文件、path 为完整 href URL、
//     跳过集合自身条目；
//  2) copyToLocal 用 GET 把远端文件下载到本地临时盘、字节一致；
//  3) readText 用 GET 读回 UTF-8 文本；
//  4) 每个请求都带 Basic 认证头（凭据经 config 注入）。
//
// WebDAV 是 HTTP-based，可完全本地 mock，故这里做真链路行为断言（比 SFTP/FTP 的
// 仅构造测试更强）；真实第三方服务器（Nextcloud 等）仍需真机验收。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:path/path.dart' as p;

/// 进程内假 WebDAV 服务器：按请求路径回 PROPFIND(207) / GET(200)。
class _FakeWebDavServer {
  _FakeWebDavServer(this.server, this.origin);

  final HttpServer server;
  final String origin;
  final List<String?> authHeaders = <String?>[];

  static const String novelBody = 'PK-novel-epub-bytes';
  static const String subEpBody = 'PK-season1-ep1-epub-bytes';
  static const String srtBody = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';

  static Future<_FakeWebDavServer> start({bool ipv6 = false}) async {
    final HttpServer srv = await HttpServer.bind(
      ipv6 ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4,
      0,
    );
    final String origin = ipv6
        ? 'http://[::1]:${srv.port}'
        : 'http://127.0.0.1:${srv.port}';
    final _FakeWebDavServer fake = _FakeWebDavServer(srv, origin);
    fake._listen();
    return fake;
  }

  Future<void> stop() => server.close(force: true);

  void _listen() {
    server.listen((HttpRequest req) async {
      authHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
      await req.drain<Object?>();
      final String path = req.uri.path;
      if (req.method == 'PROPFIND') {
        _handlePropfind(req, path);
      } else if (req.method == 'GET') {
        _handleGet(req, path);
      } else {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
      }
    });
  }

  void _respondXml(HttpRequest req, String xml) {
    req.response.statusCode = 207;
    req.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/xml; charset=utf-8',
    );
    req.response.write(xml);
    req.response.close();
  }

  void _handlePropfind(HttpRequest req, String path) {
    if (path == '/dav/books' || path == '/dav/books/') {
      _respondXml(
        req,
        _multistatus(<_DavRes>[
          const _DavRes('/dav/books/', 'books', true),
          const _DavRes('/dav/books/novel.epub', 'novel.epub', false),
          const _DavRes('/dav/books/novel.srt', 'novel.srt', false),
          const _DavRes('/dav/books/season1/', 'season1', true),
        ]),
      );
      return;
    }
    if (path == '/dav/books/season1' || path == '/dav/books/season1/') {
      _respondXml(
        req,
        _multistatus(<_DavRes>[
          const _DavRes('/dav/books/season1/', 'season1', true),
          const _DavRes('/dav/books/season1/ep1.epub', 'ep1.epub', false),
        ]),
      );
      return;
    }
    req.response.statusCode = HttpStatus.notFound;
    req.response.close();
  }

  void _handleGet(HttpRequest req, String path) {
    const Map<String, String> files = <String, String>{
      '/dav/books/novel.epub': novelBody,
      '/dav/books/novel.srt': srtBody,
      '/dav/books/season1/ep1.epub': subEpBody,
    };
    final String? body = files[path];
    if (body == null) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.close();
      return;
    }
    final List<int> bytes = utf8.encode(body);
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${bytes.length}',
    );
    req.response.add(bytes);
    req.response.close();
  }

  String _multistatus(List<_DavRes> resources) {
    final StringBuffer sb = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<d:multistatus xmlns:d="DAV:">');
    for (final _DavRes r in resources) {
      sb
        ..write('<d:response>')
        ..write('<d:href>${r.href}</d:href>')
        ..write('<d:propstat><d:prop>')
        ..write(
          r.isCollection
              ? '<d:resourcetype><d:collection/></d:resourcetype>'
              : '<d:resourcetype/>',
        )
        ..write('<d:displayname>${r.displayName}</d:displayname>')
        ..write('</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>')
        ..write('</d:response>');
    }
    sb.write('</d:multistatus>');
    return sb.toString();
  }
}

class _DavRes {
  const _DavRes(this.href, this.displayName, this.isCollection);
  final String href;
  final String displayName;
  final bool isCollection;
}

void main() {
  late _FakeWebDavServer fakeServer;
  late NetworkSourceFileSystem fs;
  late String rootUrl;

  setUp(() async {
    fakeServer = await _FakeWebDavServer.start();
    rootUrl = '${fakeServer.origin}/dav/books';
    fs = NetworkSourceFileSystem(
      NetworkSourceConfig(
        transport: 'webdav',
        host: '127.0.0.1',
        port: fakeServer.server.port,
        username: 'reader',
        password: 'pw',
      ),
    );
  });

  tearDown(() async {
    await fs.close();
    await fakeServer.stop();
  });

  test('isLocal false，config.isWebDav true', () {
    expect(fs.isLocal, isFalse);
    expect(fs.config.isWebDav, isTrue);
  });

  test('listFiles(recursive) 深度遍历只回文件，path 为完整 href URL，跳过集合自身', () async {
    final List<SourceFileEntry> entries = await fs.listFiles(
      rootUrl,
      recursive: true,
    );
    final Map<String, SourceFileEntry> byName = <String, SourceFileEntry>{
      for (final SourceFileEntry e in entries) e.name: e,
    };
    expect(byName.keys.toSet(), <String>{
      'novel.epub',
      'novel.srt',
      'ep1.epub',
    });
    expect(entries.every((SourceFileEntry e) => !e.isDirectory), isTrue);
    expect(
      byName['novel.epub']!.path,
      '${fakeServer.origin}/dav/books/novel.epub',
    );
    expect(
      byName['ep1.epub']!.path,
      '${fakeServer.origin}/dav/books/season1/ep1.epub',
    );
  });

  test('listFiles(非递归) 列直接子项：文件 + 子目录，集合自身不出现', () async {
    final List<SourceFileEntry> entries = await fs.listFiles(rootUrl);
    final Map<String, SourceFileEntry> byName = <String, SourceFileEntry>{
      for (final SourceFileEntry e in entries) e.name: e,
    };
    expect(byName.keys.toSet(), <String>{'novel.epub', 'novel.srt', 'season1'});
    expect(byName['season1']!.isDirectory, isTrue);
    expect(byName['novel.epub']!.isDirectory, isFalse);
    expect(byName['season1']!.path, '${fakeServer.origin}/dav/books/season1');
  });

  test('copyToLocal 用 GET 下载远端文件到本地临时盘，字节一致', () async {
    final Directory tmp = Directory.systemTemp.createTempSync(
      'todo1274_webdav_dl_',
    );
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String remote = '${fakeServer.origin}/dav/books/novel.epub';
    final String local = await fs.copyToLocal(remote, tmp.path);
    expect(p.basename(local), 'novel.epub');
    expect(File(local).readAsStringSync(), _FakeWebDavServer.novelBody);
  });

  test('readText 用 GET 读回 UTF-8 文本（字幕）', () async {
    final String text = await fs.readText(
      '${fakeServer.origin}/dav/books/novel.srt',
    );
    expect(text, _FakeWebDavServer.srtBody);
    expect(text, contains('こんにちは'));
  });

  test('每个请求都带 Basic 认证头（凭据经 config 注入）', () async {
    await fs.listFiles(rootUrl);
    expect(fakeServer.authHeaders, isNotEmpty);
    expect(
      fakeServer.authHeaders.every(
        (String? h) => h != null && h.startsWith('Basic '),
      ),
      isTrue,
      reason: 'WebDAV 请求必须带注入凭据的 Basic 认证头',
    );
    final String expected = 'Basic ${base64Encode(utf8.encode('reader:pw'))}';
    expect(fakeServer.authHeaders.first, expected);
  });

  // 崩溃分诊 n1i0ET11Ea：IPv6 地址的 WebDAV 端点。旧实现用 `Uri.host`（无方括号）
  // 手拼 baseUrl 与 PROPFIND 相对 href 的绝对 URL，得到 `http://::1:<port>/…`，
  // 下一次 Uri.parse 抛 `FormatException: Invalid port`，递归列目录第一层就失败。
  test('IPv6 端点：递归列目录与下载都用带方括号的 URL', () async {
    final _FakeWebDavServer v6 = await _FakeWebDavServer.start(ipv6: true);
    final NetworkSourceFileSystem v6fs = NetworkSourceFileSystem(
      NetworkSourceConfig(
        transport: 'webdav',
        host: '::1',
        port: v6.server.port,
        username: 'reader',
        password: 'pw',
      ),
    );
    addTearDown(() async {
      await v6fs.close();
      await v6.stop();
    });

    final List<SourceFileEntry> entries = await v6fs.listFiles(
      '${v6.origin}/dav/books',
      recursive: true,
    );
    final Map<String, SourceFileEntry> byName = <String, SourceFileEntry>{
      for (final SourceFileEntry e in entries) e.name: e,
    };
    expect(byName.keys.toSet(), <String>{
      'novel.epub',
      'novel.srt',
      'ep1.epub',
    });
    expect(byName['ep1.epub']!.path, '${v6.origin}/dav/books/season1/ep1.epub');
    expect(
      await v6fs.readText(byName['novel.srt']!.path),
      _FakeWebDavServer.srtBody,
    );
  });
}
