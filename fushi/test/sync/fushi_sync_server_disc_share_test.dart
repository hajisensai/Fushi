import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/disc_share_routes.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

// 远端原盘第二期：host 的只读盘目录服务（签发要 Basic，盘目录靠会话 token）。

class _DiscHost implements FushiLibraryHostService, VideoDiscShareHost {
  _DiscHost(this.discRoot);

  final String discRoot;

  @override
  Future<String?> resolveVideoDiscRoot(String id) async =>
      id == 'video/title1' ? discRoot : null;

  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<CollectionManifest> getCollectionManifest() async =>
      CollectionManifest.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被原盘共享用例触达');
}

void main() {
  const String token = 'test-token-disc-share';
  late Directory temp;
  late Directory disc;
  late FushiSyncServer server;
  late String base;
  final HttpClient client = HttpClient();

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fushi_disc_share_srv');
    disc = Directory(p.join(temp.path, 'Disc 2'));
    for (final MapEntry<String, List<int>> e in <String, List<int>>{
      'BDMV/index.bdmv': utf8.encode('INDX0200') + List<int>.filled(24, 0),
      'BDMV/PLAYLIST/00000.mpls': utf8.encode('MPLS0200'),
      'BDMV/STREAM/00000.m2ts': List<int>.generate(200, (int i) => i),
    }.entries) {
      File(p.joinAll(<String>[disc.path, ...e.key.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(e.value);
    }
    server = FushiSyncServer(
      syncDataDir: Directory(p.join(temp.path, 'sync')).path,
      port: 0,
      token: token,
      libraryService: _DiscHost(disc.path),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    temp.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> get(
    String pathOrUrl, {
    bool withAuth = true,
    String? range,
  }) async {
    final Uri uri = pathOrUrl.startsWith('http')
        ? Uri.parse(pathOrUrl)
        : Uri.parse('$base$pathOrUrl');
    final HttpClientRequest req = await client.getUrl(uri);
    if (withAuth) {
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
    }
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  Future<Map<String, dynamic>> issue() async {
    final HttpClientResponse res = await get(
      '/api/library/videos/${Uri.encodeComponent('video/title1')}/disc',
    );
    expect(res.statusCode, 200);
    return jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  }

  test('能力位 discShareV1', () async {
    final HttpClientResponse res = await get('/api/capabilities');
    final Map<String, dynamic> caps =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(
      (caps['liveLibrary'] as Map<String, dynamic>)[kDiscShareCapability],
      isTrue,
    );
  });

  test('签发要 Basic；未知标题 404', () async {
    final HttpClientResponse anon = await get(
      '/api/library/videos/video%2Ftitle1/disc',
      withAuth: false,
    );
    await anon.drain<void>();
    expect(anon.statusCode, 401);
    final HttpClientResponse missing = await get(
      '/api/library/videos/video%2Fnope/disc',
    );
    await missing.drain<void>();
    expect(missing.statusCode, 404);
  });

  test('会话：清单与文件不带 Authorization 也能取（token 在路径里），支持 Range', () async {
    final Map<String, dynamic> body = await issue();
    final String baseUrl = body['baseUrl'] as String;
    expect(baseUrl, startsWith('$base/api/library/disc/'));
    expect(baseUrl, endsWith('/'));
    final DiscShareManifest manifest = DiscShareManifest.fromJson(
      body['manifest'],
    )!;
    expect(manifest.name, 'Disc 2');
    expect(manifest.aacs, isFalse);

    final HttpClientResponse listed = await get(
      '${baseUrl}manifest.json',
      withAuth: false,
    );
    expect(listed.statusCode, 200);
    expect(
      DiscShareManifest.fromJson(
        jsonDecode(await listed.transform(utf8.decoder).join()),
      )!.files.length,
      manifest.files.length,
    );

    final HttpClientResponse part = await get(
      '${baseUrl}files/BDMV/STREAM/00000.m2ts',
      withAuth: false,
      range: 'bytes=100-109',
    );
    expect(part.statusCode, 206);
    final List<int> bytes = await part.expand((List<int> c) => c).toList();
    expect(bytes, List<int>.generate(10, (int i) => 100 + i));

    // 名字带空格的盘根照样按清单路径取（路径段经 URL 编码）。
    final HttpClientResponse index = await get(
      '${baseUrl}files/${Uri.encodeFull('BDMV/index.bdmv')}',
      withAuth: false,
    );
    expect(index.statusCode, 200);
    await index.drain<void>();
  });

  test('坏 token 401；清单外路径 404', () async {
    final String baseUrl = (await issue())['baseUrl'] as String;
    final HttpClientResponse bad = await get(
      '$base/api/library/disc/forged/manifest.json',
      withAuth: false,
    );
    await bad.drain<void>();
    expect(bad.statusCode, 401);
    final HttpClientResponse outside = await get(
      '${baseUrl}files/BDMV/../../sync/x',
      withAuth: false,
    );
    await outside.drain<void>();
    expect(outside.statusCode, 404);
  });
}
