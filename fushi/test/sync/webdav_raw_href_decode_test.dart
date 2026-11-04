import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

/// BUG-4105（反馈 N9pbmAMEHZ）：有的 WebDAV 服务端把 PROPFIND href 里的日文 / 中文原样
/// 吐出来（未百分号编码）。旧实现 `Uri.decodeFull` 一见裸非 ASCII 字符就整串抛
/// `ArgumentError: Illegal percent encoding in URI`，列同步根时只要有一本这种书，整个回包
/// 解析失败——「prune root spill (list root)」与对比差异全挂；删掉那本日文书才恢复。
void main() {
  group('decodedDavHref 宽松解码', () {
    test('裸日文字符不再抛错，原样保留', () {
      expect(
        WebDavOps.decodedDavHref('/dav/fushi-data/こころ/'),
        '/dav/fushi-data/こころ/',
      );
    });

    test('裸日文 + 合法转义混用：只解合法 %XX，sanitize 出的 %3A 仍转义回 %253A', () {
      // 文件夹名（ttu sanitize 后）字面是 `吾輩は猫である%3A 上`。
      expect(
        WebDavOps.decodedDavHref('/dav/吾輩は猫である%253A%20上/'),
        '/dav/吾輩は猫である%253A 上/',
      );
    });

    test('不成对的 % 当字面 %，非法 UTF-8 转义串保持原样', () {
      expect(WebDavOps.decodedDavHref('/dav/100%/'), '/dav/100%25/');
      expect(WebDavOps.decodedDavHref('/dav/a%zz/'), '/dav/a%25zz/');
      expect(WebDavOps.decodedDavHref('/dav/x%FF%FEy/'), '/dav/x%FF%FEy/');
    });

    test('与旧行为一致的既有形态（BUG-3576 回归）', () {
      expect(WebDavOps.decodedDavHref('/d/a%3D%231/'), '/d/a=%231/');
      expect(WebDavOps.decodedDavHref('/d/a=#1/'), '/d/a=%231/');
      expect(WebDavOps.decodedDavHref('/d/%E6%9B%B8%20x/'), '/d/書 x/');
      expect(WebDavOps.decodedDavHref('/d/50%25%3Fq/'), '/d/50%25%3Fq/');
    });

    test('readableDavSegment 解回可读名字且不抛', () {
      expect(WebDavOps.readableDavSegment('こころ'), 'こころ');
      expect(WebDavOps.readableDavSegment('Foo%253A Bar'), 'Foo%3A Bar');
      expect(WebDavOps.readableDavSegment('a=%231'), 'a=#1');
    });
  });

  group('真 HTTP：服务端回裸日文 href', () {
    late HttpServer server;
    late String base;
    final List<String> requestedPaths = <String>[];

    // 服务端磁盘上的真实目录名（ttu sanitize 后的字面）。
    const String jpFolder = 'こころ';
    const String enFolder = 'Foo%3A Bar';

    String response(String href, {required bool collection}) =>
        '<D:response><D:href>$href</D:href><D:propstat><D:prop>'
        '${collection ? '<D:resourcetype><D:collection/></D:resourcetype>' : '<D:resourcetype/>'}'
        '</D:prop></D:propstat></D:response>';

    setUp(() async {
      requestedPaths.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((HttpRequest req) async {
        await req.drain<void>();
        final String path = Uri.decodeComponent(req.uri.path);
        requestedPaths.add(path);
        final String body;
        if (req.method == 'PROPFIND' && path == '/dav/fushi-data/') {
          // 根：日文书 href 裸字符、英文书按规范编码，均无 displayname。
          body =
              '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
              '${response('/dav/fushi-data/', collection: true)}'
              '${response('/dav/fushi-data/$jpFolder/', collection: true)}'
              '${response('/dav/fushi-data/Foo%253A%20Bar/', collection: true)}'
              '${response('/dav/fushi-data/progress_1_6_1_0.5.json', collection: false)}'
              '</D:multistatus>';
        } else if (req.method == 'PROPFIND' &&
            path == '/dav/fushi-data/$jpFolder/') {
          body =
              '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
              '${response('/dav/fushi-data/$jpFolder/', collection: true)}'
              '${response('/dav/fushi-data/$jpFolder/statistics_1_6_1_2.json', collection: false)}'
              '</D:multistatus>';
        } else if (req.method == 'PROPFIND' &&
            path == '/dav/fushi-data/$enFolder/') {
          body =
              '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
              '${response('/dav/fushi-data/Foo%253A%20Bar/', collection: true)}'
              '</D:multistatus>';
        } else {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        req.response.statusCode = 207;
        req.response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        req.response.add(utf8.encode(body));
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('列根不抛；书名正确；用回包 href 继续请求命中服务端真实目录', () async {
      final WebDavOps ops = WebDavOps(
        baseUrl: '$base/dav/',
        username: 'u',
        password: 'p',
      );
      try {
        final List<DavEntry> root = await ops.propfindChildren(
          '$base/dav/fushi-data/',
        );
        final Map<String, DavEntry> byName = <String, DavEntry>{
          for (final DavEntry e in root) e.displayName: e,
        };
        expect(byName.keys, containsAll(<String>[jpFolder, enFolder]));
        expect(byName['progress_1_6_1_0.5.json']!.isCollection, isFalse);

        final List<DavEntry> jp = await ops.propfindChildren(
          byName[jpFolder]!.href,
        );
        expect(
          jp.map((DavEntry e) => e.displayName),
          contains('statistics_1_6_1_2.json'),
        );
        await ops.propfindChildren(byName[enFolder]!.href);
        expect(
          requestedPaths,
          containsAll(<String>[
            '/dav/fushi-data/$jpFolder/',
            '/dav/fushi-data/$enFolder/',
          ]),
        );
      } finally {
        ops.close(force: true);
      }
    });
  });
}
