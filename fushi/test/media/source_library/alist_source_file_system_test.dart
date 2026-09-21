// AList / OpenList 来源文件系统行为测试（无需真实站点）：
// 起一个进程内 HttpServer 冒充 AList v3 JSON API（/api/fs/list、/api/fs/get、
// /api/auth/login）+ 一个「签名直链」下载端点，验证 NetworkSourceFileSystem 的
// alist 分支真跑通：
//  1) listFiles(recursive) 递归遍历、只回文件、path 为（翻页契约见 alist_api_client_test）
//     `<根>/d/<路径>` 解码态地址、带 sizeBytes；非递归时目录单列；
//  2) copyToLocal / readText 先 fs/get 换 raw_url 再 GET，直链不带 Authorization；
//  3) 游客（账号空）任何请求都不带 Authorization；
//  4) 账号访问先 /api/auth/login 换 token，之后 API 请求带 `Authorization: <token>`。
//
// 与 webdav_source_file_system_test.dart 同范式。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/alist/alist_source_url.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:path/path.dart' as p;

class _FakeAListServer {
  _FakeAListServer(this.server, this.origin);

  final HttpServer server;
  final String origin;

  /// 每个 API 请求的 (path, Authorization) 记录。
  final List<(String, String?)> apiCalls = <(String, String?)>[];

  /// 直链下载请求的 Authorization 记录。
  final List<String?> rawAuthHeaders = <String?>[];

  static const String epBody = 'mkv-bytes-of-ep01';
  static const String assBody = '[Script Info]\nTitle: ep01\n';
  static const String token = 'alist-token-xyz';

  /// 站内树：/GD-3/罗比哈奇 RobiHachi/{#01 旅.mkv, #01 旅.chs.ass}，/GD-3/readme.txt
  static final Map<String, List<Map<String, Object?>>> tree =
      <String, List<Map<String, Object?>>>{
    '/': <Map<String, Object?>>[
      <String, Object?>{'name': 'GD-3', 'is_dir': true, 'size': 0},
    ],
    '/GD-3': <Map<String, Object?>>[
      <String, Object?>{'name': '罗比哈奇 RobiHachi', 'is_dir': true, 'size': 0},
      <String, Object?>{'name': 'readme.txt', 'is_dir': false, 'size': 3},
    ],
    '/GD-3/罗比哈奇 RobiHachi': <Map<String, Object?>>[
      <String, Object?>{
        'name': '#01 旅.mkv',
        'is_dir': false,
        'size': epBody.length,
      },
      <String, Object?>{
        'name': '#01 旅.chs.ass',
        'is_dir': false,
        'size': assBody.length,
      },
    ],
  };

  static final Map<String, String> files = <String, String>{
    '/GD-3/罗比哈奇 RobiHachi/#01 旅.mkv': epBody,
    '/GD-3/罗比哈奇 RobiHachi/#01 旅.chs.ass': assBody,
    '/GD-3/readme.txt': 'txt',
  };

  static Future<_FakeAListServer> start() async {
    final HttpServer srv =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeAListServer fake =
        _FakeAListServer(srv, 'http://127.0.0.1:${srv.port}');
    fake._listen();
    return fake;
  }

  Future<void> stop() => server.close(force: true);

  void _listen() {
    server.listen((HttpRequest req) async {
      final String path = req.uri.path;
      final String? auth = req.headers.value(HttpHeaders.authorizationHeader);
      if (path.startsWith('/api/')) {
        final Map<String, dynamic> body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        apiCalls.add((path, auth));
        _handleApi(req, path, body, auth);
        return;
      }
      await req.drain<Object?>();
      if (path.startsWith('/raw/')) {
        rawAuthHeaders.add(auth);
        final String key = Uri.decodeComponent(path.substring('/raw'.length));
        final String? content = files[key];
        if (content == null || req.uri.queryParameters['sign'] != 'ok') {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
        final List<int> bytes = utf8.encode(content);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers
            .set(HttpHeaders.contentLengthHeader, '${bytes.length}');
        req.response.add(bytes);
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });
  }

  void _json(HttpRequest req, Map<String, Object?> envelope) {
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(envelope));
    req.response.close();
  }

  void _handleApi(
    HttpRequest req,
    String path,
    Map<String, dynamic> body,
    String? auth,
  ) {
    if (path == '/api/auth/login') {
      final bool ok = body['username'] == 'alice' && body['password'] == 'pw';
      _json(req, <String, Object?>{
        'code': ok ? 200 : 400,
        'message': ok ? 'success' : 'bad credentials',
        'data': ok ? <String, Object?>{'token': token} : null,
      });
      return;
    }
    // 站点开了游客；账号访问必须带正确 token。
    if (auth != null && auth != token) {
      _json(req, <String, Object?>{'code': 401, 'message': 'bad token'});
      return;
    }
    if (path == '/api/fs/list') {
      final String dir = body['path'] as String;
      final List<Map<String, Object?>>? all = tree[dir];
      if (all == null) {
        _json(req, <String, Object?>{
          'code': 500,
          'message': 'object not found',
          'data': null,
        });
        return;
      }
      final int page = body['page'] as int;
      final int perPage = body['per_page'] as int;
      final int start = (page - 1) * perPage;
      final List<Map<String, Object?>> slice = start >= all.length
          ? <Map<String, Object?>>[]
          : all.sublist(
              start,
              (start + perPage) > all.length ? all.length : start + perPage,
            );
      _json(req, <String, Object?>{
        'code': 200,
        'message': 'success',
        'data': <String, Object?>{'content': slice, 'total': all.length},
      });
      return;
    }
    if (path == '/api/fs/get') {
      final String file = body['path'] as String;
      if (!files.containsKey(file)) {
        _json(req, <String, Object?>{
          'code': 500,
          'message': 'object not found',
          'data': null,
        });
        return;
      }
      final String encoded = file.split('/').map(Uri.encodeComponent).join('/');
      _json(req, <String, Object?>{
        'code': 200,
        'message': 'success',
        'data': <String, Object?>{
          'name': file.split('/').last,
          'size': files[file]!.length,
          'raw_url': '$origin/raw$encoded?sign=ok',
        },
      });
      return;
    }
    _json(req, <String, Object?>{'code': 404, 'message': 'no such api'});
  }
}

void main() {
  late _FakeAListServer fake;
  late Directory tmp;

  setUp(() async {
    fake = await _FakeAListServer.start();
    tmp = Directory.systemTemp.createTempSync('alist_src_fs_');
  });

  tearDown(() async {
    await fake.stop();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  NetworkSourceFileSystem guestFs() => NetworkSourceFileSystem(
        NetworkSourceConfig(
          transport: 'alist',
          host: '127.0.0.1',
          port: fake.server.port,
          username: '',
          baseUrl: fake.origin,
        ),
      );

  test('listFiles(recursive) walks the tree; entries are /d/ addresses',
      () async {
    final NetworkSourceFileSystem fs = guestFs();
    try {
      final String root =
          alistSourceUrlFor(baseUrl: fake.origin, path: '/GD-3');
      final List<SourceFileEntry> entries =
          await fs.listFiles(root, recursive: true);
      expect(entries.every((SourceFileEntry e) => !e.isDirectory), isTrue);
      expect(
        entries.map((SourceFileEntry e) => e.path).toSet(),
        <String>{
          '${fake.origin}/d/GD-3/readme.txt',
          '${fake.origin}/d/GD-3/罗比哈奇 RobiHachi/#01 旅.mkv',
          '${fake.origin}/d/GD-3/罗比哈奇 RobiHachi/#01 旅.chs.ass',
        },
        reason: '条目地址是解码态 `<根>/d/<路径>`（与 WebDAV 条目同口径）',
      );
      final SourceFileEntry mkv = entries.singleWhere(
        (SourceFileEntry e) => e.name == '#01 旅.mkv',
      );
      expect(mkv.sizeBytes, _FakeAListServer.epBody.length);
      // 游客：一个请求都不带 Authorization。
      expect(fake.apiCalls.map(((String, String?) c) => c.$2),
          everyElement(isNull));
    } finally {
      await fs.close();
    }
  });

  test('listFiles(non-recursive) lists directories as entries', () async {
    final NetworkSourceFileSystem fs = guestFs();
    try {
      final List<SourceFileEntry> entries = await fs.listFiles(
        alistSourceUrlFor(baseUrl: fake.origin, path: '/GD-3'),
      );
      expect(entries.length, 2);
      final SourceFileEntry dir = entries.singleWhere(
        (SourceFileEntry e) => e.isDirectory,
      );
      expect(dir.name, '罗比哈奇 RobiHachi');
      expect(dir.path, '${fake.origin}/d/GD-3/罗比哈奇 RobiHachi');
    } finally {
      await fs.close();
    }
  });

  test('listSiblingNames feeds sidecar matching from the same folder',
      () async {
    final NetworkSourceFileSystem fs = guestFs();
    try {
      final List<String> names = await fs.listSiblingNames(
        '${fake.origin}/d/GD-3/罗比哈奇 RobiHachi/#01 旅.mkv',
      );
      expect(names.toSet(), <String>{'#01 旅.mkv', '#01 旅.chs.ass'});
    } finally {
      await fs.close();
    }
  });

  test('copyToLocal / readText go through fs/get raw_url without auth',
      () async {
    final NetworkSourceFileSystem fs = guestFs();
    try {
      final String local = await fs.copyToLocal(
        '${fake.origin}/d/GD-3/罗比哈奇 RobiHachi/#01 旅.mkv',
        tmp.path,
      );
      expect(p.basename(local), '#01 旅.mkv');
      expect(File(local).readAsStringSync(), _FakeAListServer.epBody);
      final String text = await fs.readText(
        '${fake.origin}/d/GD-3/罗比哈奇 RobiHachi/#01 旅.chs.ass',
      );
      expect(text, _FakeAListServer.assBody);
      expect(fake.rawAuthHeaders, hasLength(2));
      expect(fake.rawAuthHeaders, everyElement(isNull),
          reason: '签名直链与 API 不同源，不得带任何认证头');
      expect(
        fake.apiCalls.where(((String, String?) c) => c.$1 == '/api/fs/get'),
        hasLength(2),
      );
    } finally {
      await fs.close();
    }
  });

  test('account access logs in once and sends the token on API calls',
      () async {
    final NetworkSourceFileSystem fs = NetworkSourceFileSystem(
      NetworkSourceConfig(
        transport: 'alist',
        host: '127.0.0.1',
        port: fake.server.port,
        username: 'alice',
        password: 'pw',
        baseUrl: fake.origin,
      ),
    );
    try {
      await fs.listFiles(
        alistSourceUrlFor(baseUrl: fake.origin, path: '/'),
        recursive: true,
      );
      final List<(String, String?)> logins = fake.apiCalls
          .where(((String, String?) c) => c.$1 == '/api/auth/login')
          .toList();
      expect(logins, hasLength(1), reason: 'token 缓存在客户端，只登一次');
      final Iterable<(String, String?)> apis = fake.apiCalls
          .where(((String, String?) c) => c.$1 != '/api/auth/login');
      expect(apis, isNotEmpty);
      expect(apis.map(((String, String?) c) => c.$2),
          everyElement(_FakeAListServer.token));
    } finally {
      await fs.close();
    }
  });

  test('address outside the /d/ namespace is rejected, not silently listed',
      () async {
    final NetworkSourceFileSystem fs = guestFs();
    try {
      await expectLater(
        fs.listFiles('${fake.origin}/GD-3'),
        throwsArgumentError,
      );
    } finally {
      await fs.close();
    }
  });
}
