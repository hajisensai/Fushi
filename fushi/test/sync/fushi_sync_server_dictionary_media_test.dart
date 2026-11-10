import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// TODO-1215: GET /api/media/dictionary serves dictionary media (gaiji /
/// pitch-accent SVG, etc.) bytes so the browser extension's rewritten <img src>
/// resolves in a real browser (which has no image:// scheme handler).
void main() {
  const String token = 'test-token-media';
  const String svg =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>';
  final Uint8List svgBytes = Uint8List.fromList(utf8.encode(svg));

  late FushiSyncServer server;
  late String base;
  final List<(String, String)> providerCalls = <(String, String)>[];

  Uint8List? provider(String dict, String path) {
    providerCalls.add((dict, path));
    if (dict == '明鏡' && path == 'gaiji/foo.svg') return svgBytes;
    return null;
  }

  setUp(() async {
    providerCalls.clear();
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_media_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      dictionaryMediaProvider: provider,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  String mediaUrl(String dict, String path, {String? tok}) {
    final Map<String, String> q = <String, String>{
      'dictionary': dict,
      'path': path,
      if (tok != null) 'token': tok,
    };
    return Uri.parse(
      '$base/api/media/dictionary',
    ).replace(queryParameters: q).toString();
  }

  test('GET with valid token returns svg bytes + image/svg+xml', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: token)),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'image/svg+xml');
    expect(res.headers.value('access-control-allow-origin'), '*');
    final List<int> body = await res.fold<List<int>>(
      <int>[],
      (List<int> a, List<int> b) => a..addAll(b),
    );
    expect(body, svgBytes);
    expect(providerCalls, contains(('明鏡', 'gaiji/foo.svg')));
    c.close();
  });

  test('HEAD with valid token returns headers, no body', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.openUrl(
      'HEAD',
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: token)),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'image/svg+xml');
    final List<int> body = await res.fold<List<int>>(
      <int>[],
      (List<int> a, List<int> b) => a..addAll(b),
    );
    expect(body, isEmpty);
    c.close();
  });

  test('GET without any token returns 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg')),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  test('GET with wrong token returns 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: 'nope')),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  test('Basic auth (no query token) also works', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg')),
    );
    req.headers.set(
      'authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    await res.drain<void>();
    c.close();
  });

  test('GET valid token but unknown media returns 404', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/missing.svg', tok: token)),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

  test('GET with empty dictionary/path returns 404', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse('$base/api/media/dictionary?dictionary=&path=&token=$token'),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

  test('POST /api/media/dictionary: query token is not an exemption for '
      'non-GET/HEAD (401); with Basic the handler answers 405', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.postUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: token)),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    final HttpClientRequest authed = await c.postUrl(
      Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg')),
    );
    authed.headers.set(
      'authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    final HttpClientResponse authedRes = await authed.close();
    expect(authedRes.statusCode, 405);
    await authedRes.drain<void>();
    c.close();
  });

  // BUG-4393：`<img>` 入口的 query 凭据可以是从任一有效凭据派生的作用域 key
  // `fmk1.`，吊销签发凭据即失效；peer token 原值不进 query（仍须 Basic）。
  group('scoped dictionary media key (fmk1)', () {
    const String peerToken = 'peer-token-media';
    final Map<String, String> peers = <String, String>{};

    setUp(() {
      peers
        ..clear()
        ..['device-a'] = peerToken;
      server.pairedPeerCredentialsProvider = () async =>
          Map<String, String>.of(peers);
      server.invalidatePeerTokenCache();
    });

    Future<int> statusOf(String tok) async {
      final HttpClient c = HttpClient();
      try {
        final HttpClientRequest req = await c.getUrl(
          Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: tok)),
        );
        final HttpClientResponse res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      } finally {
        c.close();
      }
    }

    test('key format: fmk1. + unpadded base64url HMAC-SHA256', () {
      final String key = dictionaryMediaKeyFor(peerToken);
      expect(kDictionaryMediaKeyScheme, 'fmk1');
      expect(key, startsWith('fmk1.'));
      expect(key, matches(RegExp(r'^fmk1\.[A-Za-z0-9_-]{43}$')));
      expect(dictionaryMediaKeyFor(token), isNot(key));
    });

    test('peer-derived key admits the request', () async {
      expect(await statusOf(dictionaryMediaKeyFor(peerToken)), 200);
    });

    test('revoking the peer invalidates its derived key', () async {
      final String key = dictionaryMediaKeyFor(peerToken);
      expect(await statusOf(key), 200);
      peers.remove('device-a');
      server.invalidatePeerTokenCache();
      expect(await statusOf(key), 401);
    });

    test('legacy peer derived key is admitted too', () async {
      peers['${kFushiLegacyPeerIdPrefix}x'] = 'legacy-token-media';
      server.invalidatePeerTokenCache();
      expect(await statusOf(dictionaryMediaKeyFor('legacy-token-media')), 200);
    });

    test('raw peer token in query is not accepted (Basic needed)', () async {
      expect(await statusOf(peerToken), 401);
    });

    test('shared token raw (old extension) and derived key both 200', () async {
      expect(await statusOf(token), 200);
      expect(await statusOf(dictionaryMediaKeyFor(token)), 200);
    });

    test('unknown fmk1 key is 401', () async {
      expect(await statusOf(dictionaryMediaKeyFor('nobody')), 401);
      expect(await statusOf('fmk1.'), 401);
    });

    test('/api/extension/status advertises dictionaryMediaKey', () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c.postUrl(
        Uri.parse('$base/api/extension/status'),
      );
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
      req.headers.contentType = ContentType.json;
      req.write('{}');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      final Map<String, dynamic> body =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(body['dictionaryMediaKey'], 'fmk1');
      c.close();
    });
  });

  test('media endpoint returns 404 when no provider injected', () async {
    final FushiSyncServer bare = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_media_bare').path,
      port: 0,
      token: token,
      allowLan: false,
      // dictionaryMediaProvider omitted
    );
    await bare.start();
    final String bareBase = 'http://127.0.0.1:${bare.port}';
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse(
        '$bareBase/api/media/dictionary?dictionary=D&path=x.svg&token=$token',
      ),
    );
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
    await bare.stop();
  });
}
