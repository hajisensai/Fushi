import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/dictionary/dictionary_media_types.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// 手机字幕遥控器查电脑的词典：结果来自电脑，弹框的词典样式与媒体也必须取自电脑。
/// 两个配对鉴权端点 `POST /api/lookup/dictionary/{styles,media}` 的契约与安全边界。
void main() {
  const String token = 'remote-dict-resources';
  final Uint8List svg = Uint8List.fromList(
    utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>'),
  );
  final Uint8List huge = Uint8List(kRemoteDictionaryMediaMaxBytes + 1);
  final List<(String, String)> mediaCalls = <(String, String)>[];

  late FushiSyncServer server;
  late String base;

  Uint8List? media(String dictionary, String path) {
    mediaCalls.add((dictionary, path));
    if (dictionary == '明鏡' && path == 'gaiji/a.svg') return svg;
    if (dictionary == '明鏡' && path == 'huge.png') return huge;
    return null;
  }

  Map<String, String> styles() => const <String, String>{
    '明鏡': '.gloss { color: red; }',
    '大辞林': '.sense { margin: 0; }',
  };

  setUp(() async {
    mediaCalls.clear();
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_dict_res').path,
      port: 0,
      token: token,
      allowLan: false,
      dictionaryMediaProvider: media,
      dictionaryStylesProvider: styles,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  Future<({int status, String body})> post(
    String path,
    Object body, {
    bool auth = true,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(
        Uri.parse('$base$path'),
      );
      if (auth) {
        request.headers.set(
          'authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
      }
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final HttpClientResponse response = await request.close();
      return (
        status: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
      );
    } finally {
      client.close();
    }
  }

  group('styles', () {
    test('without names returns the whole style table', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/styles',
        <String, dynamic>{},
      );
      expect(r.status, 200);
      final Map<String, dynamic> json =
          jsonDecode(r.body) as Map<String, dynamic>;
      expect(json['type'], 'dictionaryStyles');
      expect(json['styles'], styles());
    });

    test('named request returns only installed, named dictionaries', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/styles',
        <String, dynamic>{
          'dictionaries': <String>['明鏡', '未安装'],
        },
      );
      expect(r.status, 200);
      expect(
        (jsonDecode(r.body) as Map<String, dynamic>)['styles'],
        <String, String>{'明鏡': '.gloss { color: red; }'},
      );
    });

    test('malformed names are rejected', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/styles',
        <String, dynamic>{
          'dictionaries': <Object>[1, '明鏡'],
        },
      );
      expect(r.status, 400);
    });

    test('requires credentials', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/styles',
        <String, dynamic>{},
        auth: false,
      );
      expect(r.status, 401);
    });
  });

  group('media', () {
    test('returns base64 bytes with a server-decided content type', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/media',
        <String, dynamic>{'dictionary': '明鏡', 'path': './gaiji//a.svg'},
      );
      expect(r.status, 200);
      final Map<String, dynamic> json =
          jsonDecode(r.body) as Map<String, dynamic>;
      expect(json['type'], 'dictionaryMedia');
      expect(json['contentType'], 'image/svg+xml');
      expect(base64Decode(json['data'] as String), svg);
      // 规范化后的路径才交给引擎。
      expect(mediaCalls.single, ('明鏡', 'gaiji/a.svg'));
    });

    test('path traversal never reaches the provider', () async {
      for (final String path in <String>[
        '../secret.png',
        'gaiji/../../secret.png',
        r'gaiji\..\..\secret.png',
        'C:/Windows/win.ini',
        'gaiji/a.svg\u0000.png',
        '',
        '/',
        './.',
      ]) {
        final ({int status, String body}) r = await post(
          '/api/lookup/dictionary/media',
          <String, dynamic>{'dictionary': '明鏡', 'path': path},
        );
        expect(r.status, 400, reason: 'path "$path" must be rejected');
      }
      expect(mediaCalls, isEmpty);
    });

    test('oversized media is refused with 413', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/media',
        <String, dynamic>{'dictionary': '明鏡', 'path': 'huge.png'},
      );
      expect(r.status, 413);
    });

    test('unknown media is 404 and bad bodies are 400', () async {
      expect(
        (await post('/api/lookup/dictionary/media', <String, dynamic>{
          'dictionary': '明鏡',
          'path': 'missing.png',
        })).status,
        404,
      );
      expect(
        (await post('/api/lookup/dictionary/media', <String, dynamic>{
          'dictionary': '',
          'path': 'a.png',
        })).status,
        400,
      );
      expect(
        (await post('/api/lookup/dictionary/media', <String, dynamic>{
          'dictionary': '明鏡',
          'path': 3,
        })).status,
        400,
      );
    });

    test('requires credentials', () async {
      final ({int status, String body}) r = await post(
        '/api/lookup/dictionary/media',
        <String, dynamic>{'dictionary': '明鏡', 'path': 'gaiji/a.svg'},
        auth: false,
      );
      expect(r.status, 401);
      expect(mediaCalls, isEmpty);
    });
  });

  test('both endpoints are 404 when the host wires no providers', () async {
    final FushiSyncServer bare = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_dict_bare').path,
      port: 0,
      token: token,
      allowLan: false,
    );
    await bare.start();
    addTearDown(bare.stop);
    final String previous = base;
    base = 'http://127.0.0.1:${bare.port}';
    try {
      expect(
        (await post(
          '/api/lookup/dictionary/styles',
          <String, dynamic>{},
        )).status,
        404,
      );
      expect(
        (await post('/api/lookup/dictionary/media', <String, dynamic>{
          'dictionary': '明鏡',
          'path': 'gaiji/a.svg',
        })).status,
        404,
      );
    } finally {
      base = previous;
    }
  });

  test('safeDictionaryMediaPath keeps paths inside the dictionary root', () {
    expect(safeDictionaryMediaPath('gaiji/a.svg'), 'gaiji/a.svg');
    expect(safeDictionaryMediaPath(r'\img\.\b.png'), 'img/b.png');
    expect(safeDictionaryMediaPath('a/../b.png'), isNull);
    expect(safeDictionaryMediaPath('..'), isNull);
    expect(safeDictionaryMediaPath('D:evil.png'), isNull);
    expect(safeDictionaryMediaPath('a\u0000b'), isNull);
    expect(safeDictionaryMediaPath('   '), isNull);
  });
}
