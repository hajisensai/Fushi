import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';

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
    return Uri.parse('$base/api/media/dictionary')
        .replace(queryParameters: q)
        .toString();
  }

  test('GET with valid token returns svg bytes + image/svg+xml', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: token)));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'image/svg+xml');
    expect(res.headers.value('access-control-allow-origin'), '*');
    final List<int> body = await res
        .fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b));
    expect(body, svgBytes);
    expect(providerCalls, contains(('明鏡', 'gaiji/foo.svg')));
    c.close();
  });

  test('HEAD with valid token returns headers, no body', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.openUrl(
        'HEAD', Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: token)));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'image/svg+xml');
    final List<int> body = await res
        .fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b));
    expect(body, isEmpty);
    c.close();
  });

  test('GET without any token returns 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg')));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  test('GET with wrong token returns 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: 'nope')));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  test('Basic auth (no query token) also works', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg')));
    req.headers.set(
        'authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    await res.drain<void>();
    c.close();
  });

  test('GET valid token but unknown media returns 404', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c
        .getUrl(Uri.parse(mediaUrl('明鏡', 'gaiji/missing.svg', tok: token)));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

  test('GET with empty dictionary/path returns 404', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
        Uri.parse('$base/api/media/dictionary?dictionary=&path=&token=$token'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

  test('POST /api/media/dictionary returns 405 (GET/HEAD only)', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.postUrl(Uri.parse(mediaUrl('明鏡', 'gaiji/foo.svg', tok: token)));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 405);
    await res.drain<void>();
    c.close();
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
    final HttpClientRequest req = await c.getUrl(Uri.parse(
        '$bareBase/api/media/dictionary?dictionary=D&path=x.svg&token=$token'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
    await bare.stop();
  });
}
