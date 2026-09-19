// AList 来源的播放期直链解析：落库条目地址 `<根>/d/<路径>` → 起播前经 fs/get
// 换临期签名 raw_url。凭据红线同 WebDAV：账号来自 configJson、密码来自凭据存储；
// alist 来源不产出任何 Authorization 头（签名直链与 API 不同源）。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/alist/alist_stream_url_resolver.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/media/source_library/source_stream_headers.dart';
import 'package:fushi/src/media/video/stream_url_resolver.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 只实现 fs/get（+ 账号登录）的假站点，记录每次请求的 path 与 Authorization。
class _FakeGetServer {
  _FakeGetServer(this.server);

  final HttpServer server;
  final List<(String, String?)> calls = <(String, String?)>[];
  int sign = 0;

  String get origin => 'http://127.0.0.1:${server.port}';

  static Future<_FakeGetServer> start() async {
    final _FakeGetServer fake = _FakeGetServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fake.server.listen((HttpRequest req) async {
      final String body = await utf8.decoder.bind(req).join();
      final String? auth = req.headers.value(HttpHeaders.authorizationHeader);
      fake.calls.add((req.uri.path, auth));
      Map<String, Object?> envelope;
      if (req.uri.path == '/api/auth/login') {
        envelope = <String, Object?>{
          'code': 200,
          'message': 'success',
          'data': <String, Object?>{'token': 'tok'},
        };
      } else if (req.uri.path == '/api/fs/get') {
        final String path =
            (jsonDecode(body) as Map<String, dynamic>)['path'] as String;
        fake.sign++;
        envelope = <String, Object?>{
          'code': 200,
          'message': 'success',
          'data': <String, Object?>{
            'name': path.split('/').last,
            'size': 1,
            'raw_url':
                '${fake.origin}/p${Uri.encodeFull(path)}?sign=${fake.sign}',
          },
        };
      } else {
        envelope = <String, Object?>{'code': 404, 'message': 'nope'};
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(envelope));
      await req.response.close();
    });
    return fake;
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 绑定默认装一个拒绝真实网络的假 HttpClient（400 空体）；本测试要真连进程内
  // 的 loopback 假站点，复位成真客户端。
  setUpAll(() => HttpOverrides.global = null);

  late _FakeGetServer fake;
  setUp(() async => fake = await _FakeGetServer.start());
  tearDown(() => fake.stop());

  Future<int> insertAListSource(FushiDatabase db, {String username = ''}) =>
      db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'OD',
        mediaKind: 'video',
        rootPath: '${fake.origin}/d/GD-3',
        transport: const Value('alist'),
        configJson: Value(encodeSourceConfig(<String, Object?>{
          'host': '127.0.0.1',
          'port': fake.server.port,
          'username': username,
          'useTls': false,
          'baseUrl': fake.origin,
        })),
        createdAt: 1000,
      ));

  test('alist source: no auth header, resolver swaps /d/ address for raw_url',
      () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sid = await insertAListSource(db);

    expect(
      await resolveSourceStreamHeaders(
        db: db,
        sourceId: sid,
        targetUrl: '${fake.origin}/d/GD-3/ep01.mkv',
      ),
      isEmpty,
    );
    final StreamUrlResolver? resolver =
        await resolveSourceStreamUrlResolver(db: db, sourceId: sid);
    expect(resolver, isA<AListStreamUrlResolver>());
    addTearDown(resolver!.close);

    final String first =
        await resolver.resolve('${fake.origin}/d/GD-3/ep 01.mkv');
    expect(first, '${fake.origin}/p/GD-3/ep%2001.mkv?sign=1');
    final String second =
        await resolver.resolve('${fake.origin}/d/GD-3/ep 01.mkv');
    expect(second, endsWith('sign=2'), reason: '每次起播都重新换签名，不缓存过期直链');
    expect(fake.calls.map(((String, String?) c) => c.$2), everyElement(isNull),
        reason: '游客：不带 Authorization');

    // 不在本站 /d/ 命名空间下的地址原样放行（来源根下 m3u8 可指向第三方）。
    expect(
      await resolver.resolve('https://third.example.com/x.m3u8'),
      'https://third.example.com/x.m3u8',
    );
  });

  test('account from configJson + password from credential store', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sid = await insertAListSource(db, username: 'alice');
    await SourceLibraryCredentialStore(db).saveSecret(sid, password: 'pw');

    final StreamUrlResolver resolver =
        (await resolveSourceStreamUrlResolver(db: db, sourceId: sid))!;
    addTearDown(resolver.close);
    await resolver.resolve('${fake.origin}/d/GD-3/ep01.mkv');
    expect(fake.calls.first.$1, '/api/auth/login');
    expect(fake.calls.last, ('/api/fs/get', 'tok'));
  });

  test('webdav / local / missing source -> null resolver', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int dav = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'dav',
      mediaKind: 'video',
      rootPath: 'https://dav.example.com/m',
      transport: const Value('webdav'),
      createdAt: 1,
    ));
    expect(await resolveSourceStreamUrlResolver(db: db, sourceId: dav), isNull);
    expect(
        await resolveSourceStreamUrlResolver(db: db, sourceId: null), isNull);
    expect(
        await resolveSourceStreamUrlResolver(db: db, sourceId: 9999), isNull);
  });

  test('UrlStreamVideoClient applies the resolver on every stream-url request',
      () async {
    final AListStreamUrlResolver resolver =
        AListStreamUrlResolver(baseUrl: fake.origin);
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: '${fake.origin}/d/GD-3/ep01.mkv',
      subtitleUrl: '${fake.origin}/d/GD-3/ep01.ass',
      urlResolver: resolver,
      youtubeStreamRelay: (String url, Map<String, String> _) async => url,
    );
    addTearDown(client.close);
    final RemoteVideoStreamUrls a = await client.remoteVideoStreamUrls('id');
    expect(a.streamUrl, '${fake.origin}/p/GD-3/ep01.mkv?sign=1');
    expect(a.subtitleUrl, '${fake.origin}/d/GD-3/ep01.ass',
        reason: '字幕地址保持落库形态，下载时再解析');
    final RemoteVideoStreamUrls b = await client.remoteVideoStreamUrls('id');
    expect(b.streamUrl, endsWith('sign=2'));
  });
}
