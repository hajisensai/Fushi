import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

/// BUG-4393：派生凭据（视频流 token / 原盘会话 / 查词音频 id）挂在签发它的凭据上。
///
/// 此前这三张表不记签发者，`invalidatePeerTokenCache` 碰不到它们：吊销一台已配对
/// 设备后，它签出的流 URL 6 h、原盘会话 12 h、音频 URL 5 min 内照样可用。修复后
/// 每次使用都对照当前凭据快照，签发者不在快照里即 403 并删掉该派生凭据。
class _Library implements FushiLibraryHostService, VideoDiscShareHost {
  _Library({required this.video, required this.discRoot});

  final File video;
  final String discRoot;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      video;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => null;

  @override
  Future<String?> resolveVideoDiscRoot(String id) async =>
      id == 'video/title1' ? discRoot : null;

  @override
  Future<List<({String id, String path})>> videoTitlesOnDisc(
    String discRoot,
  ) async => <({String id, String path})>[
    (id: 'video/title1', path: 'BDMV/PLAYLIST/00000.mpls'),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被本用例触达');
}

class _AudioLookup implements FushiRemoteLookupService {
  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => RemoteAudioLookup(
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
    contentType: 'audio/mpeg',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被本用例触达');
}

void main() {
  const String sharedToken = 'shared-token-derived';
  const String peerToken = 'peer-token-p';
  late Directory temp;
  late FushiSyncServer server;
  late Map<String, String> peerTable;
  late String base;
  final HttpClient client = HttpClient();

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fushi_derived_revoke');
    final File video = File(p.join(temp.path, 'sample.mp4'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    final Directory disc = Directory(p.join(temp.path, 'Disc'));
    for (final MapEntry<String, List<int>> e in <String, List<int>>{
      'BDMV/index.bdmv': utf8.encode('INDX0200') + List<int>.filled(24, 0),
      'BDMV/PLAYLIST/00000.mpls': utf8.encode('MPLS0200'),
      'BDMV/STREAM/00000.m2ts': List<int>.generate(64, (int i) => i),
    }.entries) {
      File(p.joinAll(<String>[disc.path, ...e.key.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(e.value);
    }
    peerTable = <String, String>{'device-p': peerToken};
    server =
        FushiSyncServer(
            syncDataDir: p.join(temp.path, 'sync'),
            port: 0,
            token: sharedToken,
            libraryService: _Library(video: video, discRoot: disc.path),
            remoteLookupService: _AudioLookup(),
          )
          ..pairedPeerCredentialsProvider = (() async =>
              Map<String, String>.of(peerTable));
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    temp.deleteSync(recursive: true);
  });

  void revokePeer() {
    peerTable.remove('device-p');
    server.invalidatePeerTokenCache();
  }

  Future<HttpClientResponse> send(
    String method,
    String pathOrUrl, {
    String? token,
    Object? json,
  }) async {
    final Uri uri = pathOrUrl.startsWith('http')
        ? Uri.parse(pathOrUrl)
        : Uri.parse('$base$pathOrUrl');
    final HttpClientRequest req = await client.openUrl(method, uri);
    if (token != null) {
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
    }
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    return req.close();
  }

  Future<int> statusOf(String method, String url) async {
    final HttpClientResponse res = await send(method, url);
    await res.drain<void>();
    return res.statusCode;
  }

  Future<(int, String)> statusAndBody(String method, String url) async {
    final HttpClientResponse res = await send(method, url);
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  Future<Map<String, dynamic>> jsonOf(HttpClientResponse res) async {
    expect(res.statusCode, 200);
    return jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  }

  Future<String> streamUrl(String token) async =>
      (await jsonOf(
            await send(
              'GET',
              '/api/library/videos/vid-1/streamurl',
              token: token,
            ),
          ))['url']
          as String;

  test('peer 签出的视频流 URL 在吊销该 peer 后 403', () async {
    final String url = await streamUrl(peerToken);
    expect(await statusOf('GET', url), 200);

    revokePeer();

    // 第一次命中吊销分支（签发者不在快照里）；它要把这张 token 从表里删掉，于是第二次
    // 落到「未知 token」分支——比响应体才分得清（两条都是 403，评审 tests-1）。
    expect(await statusAndBody('GET', url), (403, 'Token revoked'));
    expect(await statusAndBody('GET', url), (
      403,
      'Invalid or expired token',
    ), reason: '已作废的派生凭据不留在表里');
  });

  // 评审 tests-3：HLS playlist / 分段与蓝光分段各自校验签发者。用直传 token 去点这几条
  // 路径：吊销前 token 被认（落到「不是转码流 / 不是蓝光标题」的 404），吊销后必须在
  // 那之前就回 403 Token revoked——少了哪个 handler 的签发者校验，它就仍回 404。
  for (final String suffix in <String>[
    'hls.m3u8',
    'hlsseg.ts?n=0',
    'bdclip.m2ts?n=0',
  ]) {
    test('peer 签出的 token 在吊销后取 $suffix 回 403 Token revoked', () async {
      final String token = Uri.parse(
        await streamUrl(peerToken),
      ).queryParameters['token']!;
      final String path = suffix.split('?').first;
      final String extra = suffix.contains('?')
          ? '&${suffix.split('?').last}'
          : '';
      final String url =
          '$base/api/library/videos/vid-1/$path'
          '?token=${Uri.encodeQueryComponent(token)}$extra';
      final (int before, _) = await statusAndBody('GET', url);
      expect(before, 404, reason: '吊销前 token 被认，只是这条流不是转码 / 蓝光');

      revokePeer();

      expect(await statusAndBody('GET', url), (403, 'Token revoked'));
    });
  }

  test('共享 token 签出的流 URL 不受吊销 peer 株连', () async {
    final String url = await streamUrl(sharedToken);
    revokePeer();
    expect(await statusOf('GET', url), 200);
  });

  test('peer 签出的原盘会话在吊销后 manifest 403', () async {
    final Map<String, dynamic> body = await jsonOf(
      await send(
        'GET',
        '/api/library/videos/${Uri.encodeComponent('video/title1')}/disc',
        token: peerToken,
      ),
    );
    final String manifest = '${body['baseUrl'] as String}manifest.json';
    expect(await statusOf('GET', manifest), 200);

    revokePeer();

    expect(await statusOf('GET', manifest), 403);
  });

  test('peer 签出的查词音频 URL 在吊销后 403', () async {
    final Map<String, dynamic> body = await jsonOf(
      await send(
        'POST',
        '/api/lookup/audio',
        token: peerToken,
        json: <String, String>{'expression': '猫', 'reading': 'ねこ'},
      ),
    );
    final String url = body['url'] as String;
    expect(await statusOf('GET', url), 200);

    revokePeer();

    expect(await statusOf('GET', url), 403);
  });
}
