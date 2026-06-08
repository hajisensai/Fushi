import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

/// Fake 库服务：视频方法真实、其他方法存根。
///
/// 包含一个 id 含斜杠的视频（bookUid = `video/sample`），指向临时视频文件和字幕文件。
class _FakeLibraryService implements HibikiLibraryHostService {
  _FakeLibraryService() {
    // 创建临时视频文件（内容为已知字节）
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_test');
    videoFile = File('${tmp.path}/sample.mp4');
    videoFile.writeAsBytesSync(_videoBytes);
    // 创建临时字幕文件
    subtitleFile = File('${tmp.path}/sample.ja.srt');
    subtitleFile.writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nテスト\n');
  }

  static final List<int> _videoBytes = List<int>.generate(16, (int i) => i);

  late final File videoFile;
  late final File subtitleFile;

  /// id 含斜杠，模拟真实 VideoBooks.bookUid
  static const String videoId = 'video/sample';

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: videoId,
          title: 'Sample Video',
          sizeBytes: 16,
          hasSubtitle: true,
        ),
      ];

  @override
  Future<File?> resolveVideoFile(String id) async {
    if (id == videoId) return videoFile;
    return null;
  }

  @override
  Future<File?> resolveVideoSubtitle(String id,
      {String langCode = 'ja'}) async {
    if (id == videoId) return subtitleFile;
    return null;
  }

  // ── dict stubs ──────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError('not used in video test');

  @override
  Future<void> importDictionary(File packageFile) async {}

  @override
  Future<void> deleteDictionary(String name) async {}

  // ── books stubs ─────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('not used in video test');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  // ── local audio stubs ───────────────────────────────────────────────────────
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError('not used in video test');

  @override
  Future<void> importLocalAudio(File packageFile) async {}

  @override
  Future<void> deleteLocalAudio(String displayName) async {}

  // ── audiobook stubs ─────────────────────────────────────────────────────────
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async =>
      <RemoteAudiobookInfo>[];

  @override
  Future<File> exportAudiobook(String bookKey) async =>
      throw UnimplementedError('not used in video test');

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}
}

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  const String token = 'test-token-video';
  late String base;
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_vid_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  // ── capabilities ─────────────────────────────────────────────────────────────

  test('GET /api/capabilities 包含 videos == true', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/capabilities'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    final Map<dynamic, dynamic> live =
        json['liveLibrary'] as Map<dynamic, dynamic>;
    expect(live['videos'], true,
        reason: '注入了 libraryService 时 videos 能力应为 true');
    c.close();
  });

  // ── list ─────────────────────────────────────────────────────────────────────

  test('GET /api/library/videos 列出视频（需 Basic 鉴权）', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/videos'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
    expect(json.length, 1);
    final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
    expect(first['id'], 'video/sample', reason: 'id 含斜杠应被正确序列化');
    expect(first['title'], 'Sample Video');
    expect(first['hasSubtitle'], true);
    c.close();
  });

  test('GET /api/library/videos 未鉴权返回 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/videos'));
    // 不设 Authorization 头
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  // ── streamurl ──────────────────────────────────────────────────────────────

  test('GET /api/library/videos/<id>/streamurl 返回含 token 的 stream url',
      () async {
    final HttpClient c = HttpClient();
    final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
    final HttpClientRequest req = await c
        .getUrl(Uri.parse('$base/api/library/videos/$encodedId/streamurl'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(json['url'], isNotNull, reason: '应有 stream url');
    final String url = json['url'] as String;
    expect(url, contains('/stream'), reason: 'url 应指向 stream 端点');
    expect(url, contains('token='), reason: 'url 应携带 token 参数');
    expect(json['subtitleUrl'], isNotNull, reason: '有字幕时应返回 subtitleUrl');
    c.close();
  });

  test('GET /api/library/videos/<id>/streamurl 未鉴权返回 401', () async {
    final HttpClient c = HttpClient();
    final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
    final HttpClientRequest req = await c
        .getUrl(Uri.parse('$base/api/library/videos/$encodedId/streamurl'));
    // 不设 Authorization 头
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  // ── stream（token 鉴权，豁免 Basic）──────────────────────────────────────────

  group('video stream', () {
    /// 取得有效 stream url（含 token）。
    Future<String> getStreamUrl(HttpClient c) async {
      final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
      final HttpClientRequest req = await c
          .getUrl(Uri.parse('$base/api/library/videos/$encodedId/streamurl'));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200, reason: '取流地址应成功');
      final Map<String, dynamic> json =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      return json['url'] as String;
    }

    test('GET stream（不带 Basic、带有效 token）→ 200 全量 + Accept-Ranges', () async {
      final HttpClient c = HttpClient();
      final String streamUrl = await getStreamUrl(c);
      final HttpClientRequest req = await c.getUrl(Uri.parse(streamUrl));
      // 故意不设 Authorization 头（测试豁免 Basic）
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200);
      expect(res.headers.value('accept-ranges'), 'bytes',
          reason: '应携带 Accept-Ranges: bytes');
      final List<int> body =
          await res.fold(<int>[], (List<int> a, List<int> b) {
        return a..addAll(b);
      });
      expect(body.length, 16, reason: '应返回全部 16 字节');
      expect(body, List<int>.generate(16, (int i) => i),
          reason: '内容应与 fake 视频文件一致');
      c.close();
    });

    test('GET stream 带 Range: bytes=0-3 → 206 + Content-Range + 4 字节',
        () async {
      final HttpClient c = HttpClient();
      final String streamUrl = await getStreamUrl(c);
      final HttpClientRequest req = await c.getUrl(Uri.parse(streamUrl));
      req.headers.set('range', 'bytes=0-3');
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 206, reason: 'Range 请求应返回 206 Partial Content');
      expect(res.headers.value('content-range'), 'bytes 0-3/16',
          reason: 'Content-Range 应为 bytes 0-3/16');
      final List<int> body =
          await res.fold(<int>[], (List<int> a, List<int> b) {
        return a..addAll(b);
      });
      expect(body.length, 4, reason: 'body 应为 4 字节');
      expect(body, <int>[0, 1, 2, 3], reason: '字节内容应为 0..3');
      c.close();
    });

    test('GET stream 带无效 token → 403', () async {
      final HttpClient c = HttpClient();
      final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
      final HttpClientRequest req = await c.getUrl(Uri.parse(
          '$base/api/library/videos/$encodedId/stream?token=invalid_token_xyz'));
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 403, reason: '无效 token 应返回 403，不能泄漏文件内容');
      await res.drain<void>();
      c.close();
    });

    test('GET stream token 对应不同 video id → 403', () async {
      final HttpClient c = HttpClient();
      // 先取一个合法 token
      final String streamUrl = await getStreamUrl(c);
      final Uri streamUri = Uri.parse(streamUrl);
      final String tokenValue = streamUri.queryParameters['token']!;
      // 用合法 token 但配一个不存在的 id
      final HttpClientRequest req = await c.getUrl(Uri.parse(
          '$base/api/library/videos/video/other/stream?token=$tokenValue'));
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(403, 404), reason: '合法 token 配错误 id 应被拒绝');
      await res.drain<void>();
      c.close();
    });

    test('GET stream 不带 token 且不带 Basic → 401', () async {
      final HttpClient c = HttpClient();
      final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
      final HttpClientRequest req = await c
          .getUrl(Uri.parse('$base/api/library/videos/$encodedId/stream'));
      // 不带任何鉴权
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, anyOf(401, 403),
          reason: '豁免 Basic 后但无 token，handler 应拒绝');
      await res.drain<void>();
      c.close();
    });
  });

  // ── subtitle ─────────────────────────────────────────────────────────────────

  test('GET /api/library/videos/<id>/subtitle（带 Basic）→ 200 字幕内容', () async {
    final HttpClient c = HttpClient();
    final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
    final HttpClientRequest req = await c
        .getUrl(Uri.parse('$base/api/library/videos/$encodedId/subtitle'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final String body = await res.transform(utf8.decoder).join();
    expect(body, contains('テスト'), reason: '应返回字幕内容');
    c.close();
  });

  test('GET /api/library/videos/<id>/subtitle 未鉴权返回 401', () async {
    final HttpClient c = HttpClient();
    final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
    final HttpClientRequest req = await c
        .getUrl(Uri.parse('$base/api/library/videos/$encodedId/subtitle'));
    // 不设 Authorization 头
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    await res.drain<void>();
    c.close();
  });

  test('GET /api/library/videos/<missing-id>/subtitle 返回 404', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c
        .getUrl(Uri.parse('$base/api/library/videos/video/no_such/subtitle'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

  // ── path traversal ────────────────────────────────────────────────────────────

  test('id 含 .. 的穿越尝试 → 403 或 404', () async {
    final HttpClient c = HttpClient();

    // streamurl 端点：`/api/library/videos/../evil/streamurl`
    final HttpClientRequest req1 = await c.getUrl(Uri.parse(
        '$base/api/library/videos/${Uri.encodeFull('../evil')}/streamurl'));
    req1.headers.set('authorization', authHeader());
    final HttpClientResponse res1 = await req1.close();
    expect(res1.statusCode, anyOf(400, 403, 404), reason: '含 .. 的 id 应被拒绝');
    await res1.drain<void>();

    // subtitle 端点
    final HttpClientRequest req2 = await c.getUrl(Uri.parse(
        '$base/api/library/videos/${Uri.encodeFull('../evil')}/subtitle'));
    req2.headers.set('authorization', authHeader());
    final HttpClientResponse res2 = await req2.close();
    expect(res2.statusCode, anyOf(400, 403, 404),
        reason: '含 .. 的 id 在 subtitle 端点应被拒绝');
    await res2.drain<void>();

    c.close();
  });

  // ── no service injected ───────────────────────────────────────────────────────

  test('无 service 注入时视频端点返回 404', () async {
    final HibikiSyncServer bare = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_vid_bare').path,
      port: 0,
      token: token,
      allowLan: false,
      // libraryService 为 null
    );
    await bare.start();
    final String bareBase = 'http://127.0.0.1:${bare.port}';
    final HttpClient c = HttpClient();

    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$bareBase/api/library/videos'));
    req.headers.set(
        'authorization', 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404, reason: '无 libraryService 时视频列表应返回 404');
    await res.drain<void>();

    c.close();
    await bare.stop();
  });
}
