import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// 互联 host 的鉴权豁免必须和路由分发看同一份规范化路径，并且只对 handler 真正
/// 受理的方法豁免。
///
/// 此前 auth 中间件按编码形式的 `request.url.path` 判豁免、任意方法都放行，路由却按
/// `Uri.decodeFull('/${request.url.path}')` 分发：豁免路径上的非豁免方法（`POST
/// /api/ping`、`PUT .../stream`）不经鉴权就进了 handler；`%2F` 编码的流路径豁免不命中、
/// 而路由解码后照样分发到 stream handler。两种形态各说各话，安全全靠 handler 自补。
///
/// 只实现 streamurl / stream 需要的两个方法，其余经 noSuchMethod 抛（本测试不该触达）。
class _StreamOnlyLibraryService implements FushiLibraryHostService {
  _StreamOnlyLibraryService(this.videoFile);

  final File videoFile;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      videoFile;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('互联鉴权豁免：规范化路径 + 方法单表', () {
    late FushiSyncServer server;
    late Directory tempDir;
    late HttpClient client;
    const String token = 'public-route-table';
    late String base;

    String authHeader() =>
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('hbk_public_routes');
      final File video = File('${tempDir.path}/sample.mp4')
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      server = FushiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _StreamOnlyLibraryService(video),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<({int status, String body})> send(
      String method,
      String pathAndQuery, {
      bool auth = false,
    }) async {
      final HttpClientRequest req = await client.openUrl(
        method,
        Uri.parse('$base$pathAndQuery'),
      );
      if (auth) req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      final String body = await utf8.decodeStream(res);
      return (status: res.statusCode, body: body);
    }

    test('无鉴权 POST /api/ping 被鉴权拦下（401），不进 handler', () async {
      expect((await send('POST', '/api/ping')).status, 401);
      // 豁免方法照旧放行。
      expect((await send('GET', '/api/ping')).status, 200);
    });

    test('无鉴权 PUT 视频流路径被鉴权拦下（401）', () async {
      expect((await send('PUT', '/api/library/videos/x/stream')).status, 401);
    });

    test('编码路径 abc%2Fstream 按规范化路径命中流豁免，凭流 token 取到流', () async {
      final ({int status, String body}) issued = await send(
        'GET',
        '/api/library/videos/abc/streamurl',
        auth: true,
      );
      expect(issued.status, 200);
      final Map<String, dynamic> json =
          jsonDecode(issued.body) as Map<String, dynamic>;
      final String streamToken = Uri.parse(
        json['url'] as String,
      ).queryParameters['token']!;
      expect(streamToken, isNotEmpty);

      final ({int status, String body}) streamed = await send(
        'GET',
        '/api/library/videos/abc%2Fstream?token=$streamToken',
      );
      expect(streamed.status, 200);
    });

    test('OPTIONS 预检不被鉴权拦', () async {
      expect((await send('OPTIONS', '/api/library/videos')).status, isNot(401));
    });

    test('流路径不带 token 仍由 handler 拒', () async {
      final ({int status, String body}) res = await send(
        'GET',
        '/api/library/videos/abc/stream',
      );
      expect(res.status, 401);
      expect(res.body, 'Missing token');
    });

    test('裸视频 id 不能以流子路径结尾（PUT 带 Basic 也不当上传）', () async {
      final ({int status, String body}) res = await send(
        'PUT',
        '/api/library/videos/abc/stream',
        auth: true,
      );
      expect(res.status, 405);
    });

    test('解不出规范化路径的请求（非法 UTF-8 转义）统一 400，鉴权前后一致', () async {
      expect((await send('GET', '/api/library/videos/%FF/stream')).status, 400);
      expect(
        (await send(
          'GET',
          '/api/library/videos/%FF/stream',
          auth: true,
        )).status,
        400,
      );
    });
  });
}
