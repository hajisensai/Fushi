import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';

/// loopback HTTP fake（照 `manga_ocr_model_downloader_test.dart` 的
/// `_ModelServer` 思路）：按路径供响应体，记录完整请求 URI。
class _CatalogServer {
  _CatalogServer(this.server) {
    server.listen(_handle);
  }

  final HttpServer server;
  final Map<String, String> bodies = <String, String>{};
  final List<Uri> requests = <Uri>[];

  static Future<_CatalogServer> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _CatalogServer(server);
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);

  void _handle(HttpRequest request) {
    requests.add(request.uri);
    final String? body = bodies[request.uri.path];
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.add(utf8.encode(body));
    request.response.close();
  }
}

void main() {
  late _CatalogServer server;

  setUp(() async {
    server = await _CatalogServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  /// 测试直连 loopback，绕开环境代理变量（生产默认 findProxyFromEnvironment）。
  MokuroMoeClient client() =>
      MokuroMoeClient(baseUrl: server.baseUrl, createClient: HttpClient.new);

  test('fetchLibrary 解析系列 + 卷，字段缺失容错', () async {
    server.bodies['/catalog/api/library'] = jsonEncode(<String, Object?>{
      'series': <Object?>[
        <String, Object?>{
          'name': 'よつばと!',
          'path': 'よつばと!',
          'cover': 'よつばと!/cover.webp',
          'volumes': <Object?>[
            <String, Object?>{
              'name': 'よつばと! 第01巻',
              'cover': 'よつばと!/v01.webp',
              'ocr_pending': false,
              'ocr_active': false,
            },
            // 字段缺失：全部取默认值，不炸。
            <String, Object?>{'name': 'よつばと! 第02巻'},
          ],
        },
        // volumes 缺失 / cover 类型不符：容错为空。
        <String, Object?>{'name': 'ヨコハマ買い出し紀行', 'cover': 42},
      ],
    });

    final List<MokuroMoeSeries> library = await client().fetchLibrary();

    expect(library, hasLength(2));
    expect(library[0].name, 'よつばと!');
    expect(library[0].cover, 'よつばと!/cover.webp');
    expect(library[0].volumes, hasLength(2));
    expect(library[0].volumes[0].name, 'よつばと! 第01巻');
    expect(library[0].volumes[1].cover, '');
    expect(library[0].volumes[1].ocrPending, isFalse);
    expect(library[1].cover, '');
    expect(library[1].volumes, isEmpty);
  });

  test('fetchSeries：特殊字符系列名（#、空格）经 query 编码往返', () async {
    server.bodies['/catalog/api/series'] = jsonEncode(<String, Object?>{
      'name': 'Comic #1 スペース入り',
      'volumes': <Object?>[
        <String, Object?>{'name': 'v1'},
      ],
    });

    final MokuroMoeSeries series =
        await client().fetchSeries('Comic #1 スペース入り');

    expect(series.name, 'Comic #1 スペース入り');
    expect(series.volumes.single.name, 'v1');
    // 服务器端解出的 query 参数必须逐字节还原（# 未编码会被当 fragment 截断）。
    expect(
      server.requests.single.queryParameters['name'],
      'Comic #1 スペース入り',
    );
  });

  test('cbzUrl / mokuroUrl / coverUrl：URL 段逐段 encodeComponent', () {
    final MokuroMoeClient c = client();
    final String cbz = c.cbzUrl('Comic #1', '第01巻 (extra)');
    expect(cbz,
        '${server.baseUrl}/mokuro-reader/Comic%20%231/%E7%AC%AC01%E5%B7%BB%20(extra).cbz');
    final String mokuro = c.mokuroUrl('Comic #1', '第01巻 (extra)');
    expect(mokuro, endsWith('.mokuro'));
    expect(mokuro, contains('Comic%20%231'));
    final String cover = c.coverUrl('Comic #1/cover file.webp');
    expect(cover,
        '${server.baseUrl}/catalog/api/cover?path=Comic%20%231%2Fcover%20file.webp');
  });

  test('非 200 抛 HttpException', () async {
    await expectLater(
      client().fetchLibrary(),
      throwsA(isA<HttpException>()),
    );
    await expectLater(
      client().fetchSeries('missing'),
      throwsA(isA<HttpException>()),
    );
  });

  test('base URL 归一：尾斜杠去除、空串回退默认站点', () {
    expect(MokuroMoeClient(baseUrl: 'https://example.com///').baseUrl,
        'https://example.com');
    expect(MokuroMoeClient(baseUrl: '   ').baseUrl, kMokuroMoeDefaultBaseUrl);
    expect(MokuroMoeClient().baseUrl, kMokuroMoeDefaultBaseUrl);
    expect(normalizeMokuroMoeBaseUrl(''), kMokuroMoeDefaultBaseUrl);
  });
}
