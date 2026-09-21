/// 浏览器扩展字幕外观「字体」下拉框的三路端点（`/api/extension/fonts` /
/// `fonts/file` / `fonts/download`）在 [YomitanApiServer] 上的 HTTP 契约：
/// 列表形状、字节端点的 200/404/HEAD/CORS/鉴权、下载的 unknown_font / download_failed。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/extension_font_api.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';
import 'package:path/path.dart' as p;

class _FakeLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      null;
}

class _FakeFontApi implements ExtensionFontApi {
  final List<ExtensionFontEntry> fonts = <ExtensionFontEntry>[];
  final List<ExtensionRecommendedFont> recommended =
      <ExtensionRecommendedFont>[];
  final List<String> downloadRequests = <String>[];
  ExtensionFontDownloadOutcome Function(String name)? onDownload;

  @override
  Future<List<ExtensionFontEntry>> listFonts() async => fonts;

  @override
  Future<List<ExtensionRecommendedFont>> listRecommended() async => recommended;

  @override
  Future<ExtensionFontEntry?> findFont(String id) async {
    for (final ExtensionFontEntry f in fonts) {
      if (f.id == id) return f;
    }
    return null;
  }

  @override
  Future<ExtensionFontDownloadOutcome> downloadRecommended(String name) async {
    downloadRequests.add(name);
    return onDownload?.call(name) ??
        const ExtensionFontDownloadOutcome.unknownFont();
  }
}

List<String> _noopTokenize(String text) => const <String>[];
String _noopReading(String word) => '';

String _basic(String token) =>
    'Basic ${base64Encode(utf8.encode('fushi:$token'))}';

Future<HttpClientResponse> _post(
  int port,
  String path,
  Map<String, dynamic> body, {
  String? auth,
}) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest req =
      await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
  req.headers.contentType = ContentType.json;
  if (auth != null) req.headers.set('authorization', auth);
  req.write(jsonEncode(body));
  return req.close();
}

Future<HttpClientResponse> _request(String method, String url) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest req = await c.openUrl(method, Uri.parse(url));
  return req.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async {
  final String s = await resp.transform(utf8.decoder).join();
  return jsonDecode(s) as Map<String, dynamic>;
}

Future<List<int>> _collectBytes(HttpClientResponse resp) async {
  final List<int> out = <int>[];
  await for (final List<int> chunk in resp) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  const Tokenizer tok = _noopTokenize;
  const ReadingResolver rr = _noopReading;
  final Uint8List ttfBytes = Uint8List.fromList(
    <int>[0x00, 0x01, 0x00, 0x00, ...List<int>.filled(32, 0x42)],
  );

  late Directory tmp;
  late _FakeFontApi api;
  late YomitanApiServer server;

  Future<void> startServer(
      {String? apiKey = 'k123', bool withApi = true}) async {
    server = YomitanApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: tok,
      readingResolver: rr,
      fontApi: withApi ? api : null,
      apiKey: apiKey,
    );
    await server.start();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_ext_fonts_');
    final File ttf = File(p.join(tmp.path, 'KleeOne_1.ttf'));
    await ttf.writeAsBytes(ttfBytes);
    api = _FakeFontApi()
      ..fonts.add(ExtensionFontEntry(
        id: 'font_1',
        name: 'Klee One',
        family: 'Klee One',
        ext: 'ttf',
        path: ttf.path,
      ))
      ..fonts.add(ExtensionFontEntry(
        id: 'font_2',
        name: 'Gone',
        family: 'Gone',
        ext: 'woff2',
        path: p.join(tmp.path, 'missing.woff2'),
      ))
      ..recommended.add(const ExtensionRecommendedFont(
        name: 'Klee One',
        nameJa: 'クレー One',
        description: 'desc',
        license: 'OFL 1.1',
        installed: true,
      ));
  });

  tearDown(() async {
    await server.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('POST /api/extension/fonts 回目录字体 + 推荐表', () async {
    await startServer();
    final HttpClientResponse resp = await _post(
      server.port,
      '/api/extension/fonts',
      <String, dynamic>{},
      auth: _basic('k123'),
    );
    expect(resp.statusCode, 200);
    final Map<String, dynamic> j = await _json(resp);
    final List<dynamic> fonts = j['fonts'] as List<dynamic>;
    expect(fonts, hasLength(2));
    expect(fonts.first, <String, dynamic>{
      'id': 'font_1',
      'name': 'Klee One',
      'family': 'Klee One',
      'ext': 'ttf',
    });
    // 绝对路径不上 wire。
    expect((fonts.first as Map<String, dynamic>).containsKey('path'), isFalse);
    final List<dynamic> recommended = j['recommended'] as List<dynamic>;
    expect(recommended.single, <String, dynamic>{
      'name': 'Klee One',
      'nameJa': 'クレー One',
      'description': 'desc',
      'license': 'OFL 1.1',
      'installed': true,
    });
  });

  test('未注入 fontApi 时三路都是 404', () async {
    await startServer(withApi: false);
    expect(
      (await _post(server.port, '/api/extension/fonts', <String, dynamic>{},
              auth: _basic('k123')))
          .statusCode,
      404,
    );
    expect(
      (await _request('GET',
              'http://127.0.0.1:${server.port}/api/extension/fonts/file?id=font_1&token=k123'))
          .statusCode,
      404,
    );
    expect(
      (await _post(
        server.port,
        '/api/extension/fonts/download',
        <String, dynamic>{'name': 'Klee One'},
        auth: _basic('k123'),
      ))
          .statusCode,
      404,
    );
  });

  group('GET /api/extension/fonts/file', () {
    test('200 + 字节 + font/ttf + CORS + Cache-Control', () async {
      await startServer();
      final HttpClientResponse resp = await _request(
        'GET',
        'http://127.0.0.1:${server.port}/api/extension/fonts/file?id=font_1&token=k123',
      );
      expect(resp.statusCode, 200);
      expect(resp.headers.value('content-type'), 'font/ttf');
      expect(resp.headers.value('content-length'), '${ttfBytes.length}');
      expect(resp.headers.value('access-control-allow-origin'), '*');
      expect(resp.headers.value('cache-control'), 'private, max-age=86400');
      expect(await _collectBytes(resp), ttfBytes);
    });

    test('HEAD 只回头不回体，Content-Length 仍是文件长度', () async {
      await startServer();
      final HttpClientResponse resp = await _request(
        'HEAD',
        'http://127.0.0.1:${server.port}/api/extension/fonts/file?id=font_1&token=k123',
      );
      expect(resp.statusCode, 200);
      expect(resp.headers.value('content-type'), 'font/ttf');
      expect(resp.headers.value('content-length'), '${ttfBytes.length}');
      expect(resp.headers.value('access-control-allow-origin'), '*');
      expect(await _collectBytes(resp), isEmpty);
    });

    test('id 不在目录 / 文件不存在 / 缺 id → 404', () async {
      await startServer();
      final String base = 'http://127.0.0.1:${server.port}';
      expect(
        (await _request(
                'GET', '$base/api/extension/fonts/file?id=nope&token=k123'))
            .statusCode,
        404,
      );
      expect(
        (await _request(
                'GET', '$base/api/extension/fonts/file?id=font_2&token=k123'))
            .statusCode,
        404,
      );
      expect(
        (await _request('GET', '$base/api/extension/fonts/file?token=k123'))
            .statusCode,
        404,
      );
    });

    test('无 token / 错 token → 401（不在免鉴权白名单）', () async {
      await startServer();
      final String base = 'http://127.0.0.1:${server.port}';
      expect(
        (await _request('GET', '$base/api/extension/fonts/file?id=font_1'))
            .statusCode,
        401,
      );
      expect(
        (await _request(
                'GET', '$base/api/extension/fonts/file?id=font_1&token=wrong'))
            .statusCode,
        401,
      );
    });

    test('未设 apiKey 时裸 GET 放行（与其它端点同语义）', () async {
      await startServer(apiKey: null);
      expect(
        (await _request('GET',
                'http://127.0.0.1:${server.port}/api/extension/fonts/file?id=font_1'))
            .statusCode,
        200,
      );
    });

    test('POST 到 file 端点 → 405', () async {
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/fonts/file?id=font_1',
        <String, dynamic>{},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 405);
    });

    test('MIME 按扩展名映射，未知扩展名回 octet-stream', () {
      expect(ExtensionFontEntry.contentTypeForExt('ttf'), 'font/ttf');
      expect(ExtensionFontEntry.contentTypeForExt('OTF'), 'font/otf');
      expect(ExtensionFontEntry.contentTypeForExt('woff'), 'font/woff');
      expect(ExtensionFontEntry.contentTypeForExt('woff2'), 'font/woff2');
      expect(ExtensionFontEntry.contentTypeForExt('ttc'), 'font/collection');
      expect(
        ExtensionFontEntry.contentTypeForExt('bin'),
        'application/octet-stream',
      );
    });
  });

  group('POST /api/extension/fonts/download', () {
    test('未知字体 → 404 unknown_font', () async {
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/fonts/download',
        <String, dynamic>{'name': 'Nope Sans'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 404);
      expect(await _json(resp), <String, dynamic>{
        'ok': false,
        'error': 'unknown_font',
      });
      expect(api.downloadRequests, <String>['Nope Sans']);
    });

    test('成功 → 200 ok + 条目', () async {
      api.onDownload =
          (String name) => ExtensionFontDownloadOutcome.ok(<ExtensionFontEntry>[
                api.fonts.first,
              ]);
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/fonts/download',
        <String, dynamic>{'name': 'Klee One'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['ok'], true);
      expect(j['fonts'], <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'font_1',
          'name': 'Klee One',
          'family': 'Klee One',
          'ext': 'ttf',
        },
      ]);
    });

    test('下载失败 → 502 download_failed + detail', () async {
      api.onDownload = (String name) =>
          const ExtensionFontDownloadOutcome.failed('connectionTimeout');
      await startServer();
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/extension/fonts/download',
        <String, dynamic>{'name': 'Klee One'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 502);
      expect(await _json(resp), <String, dynamic>{
        'ok': false,
        'error': 'download_failed',
        'detail': 'connectionTimeout',
      });
    });

    test('缺 name → 400；无鉴权 → 401', () async {
      await startServer();
      expect(
        (await _post(
          server.port,
          '/api/extension/fonts/download',
          <String, dynamic>{},
          auth: _basic('k123'),
        ))
            .statusCode,
        400,
      );
      expect(
        (await _post(
          server.port,
          '/api/extension/fonts/download',
          <String, dynamic>{'name': 'Klee One'},
        ))
            .statusCode,
        401,
      );
      expect(api.downloadRequests, isEmpty);
    });
  });
}
