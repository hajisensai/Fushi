import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

const List<int> _coverBytes = <int>[0x89, 0x50, 0x4e, 0x47, 5, 6, 7, 8];

DateTime _uniqueSubtitleCacheMtime(String seed) {
  final int offsetMs = seed.hashCode & 0x3fffffff;
  return DateTime.fromMillisecondsSinceEpoch(1700000000000 + offsetMs);
}

/// Fake 库服务：视频方法真实、其他方法存根。
///
/// 包含一个 id 含斜杠的视频（bookUid = `video/sample`），指向临时视频文件和字幕文件。
class _FakeLibraryService implements HibikiLibraryHostService {
  _FakeLibraryService() {
    // 创建临时视频文件（内容为已知字节）
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_test');
    videoFile = File('${tmp.path}/sample.mp4');
    videoFile.writeAsBytesSync(_videoBytes);
    videoFile.setLastModifiedSync(_uniqueSubtitleCacheMtime(tmp.path));
    // 创建临时字幕文件：用 ASS 覆盖远端 sidecar 不能退化成 .srt 的协议契约。
    subtitleFile = File('${tmp.path}/sample.ja.ass');
    subtitleFile.writeAsStringSync(
      '[Script Info]\n'
      'Title: test\n'
      '[Events]\n'
      'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,テスト\n',
    );
    coverFile = File('${tmp.path}/sample.png')..writeAsBytesSync(_coverBytes);
    // TODO-885 多集播放列表 fake：两集各自的视频文件（按 episodeIndex 反查）。
    ep0File = File('${tmp.path}/ep0.mp4')
      ..writeAsBytesSync(<int>[10, 11, 12, 13]);
    ep1File = File('${tmp.path}/ep1.mp4')
      ..writeAsBytesSync(<int>[20, 21, 22, 23, 24]);
    ep1SubFile = File('${tmp.path}/ep1.ja.srt')..writeAsStringSync('ep1 sub');
  }

  static final List<int> _videoBytes = List<int>.generate(16, (int i) => i);

  late final File videoFile;
  late final File subtitleFile;
  late final File coverFile;
  late final File ep0File;
  late final File ep1File;
  late final File ep1SubFile;

  /// id 含斜杠，模拟真实 VideoBooks.bookUid
  static const String videoId = 'video/sample';

  /// TODO-885 多集播放列表 id（含斜杠）。
  static const String playlistId = 'video/playlist';

  @override
  Future<List<RemoteVideoInfo>> listVideos() async {
    // 镜像生产 _videoInfoFromRow：清单条目带上 host 记录的播放进度（TODO-653）。
    final ({int positionMs, int updatedAtMs}) p =
        await getVideoPosition(videoId);
    return <RemoteVideoInfo>[
      RemoteVideoInfo.fromJson(<String, Object?>{
        'id': videoId,
        'title': 'Sample Video',
        'sizeBytes': 16,
        'hasSubtitle': true,
        'coverPath': coverFile.path,
        'positionMs': p.positionMs,
        'positionUpdatedAtMs': p.updatedAtMs,
      }),
    ];
  }

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async {
    if (id == videoId) return videoFile;
    if (id == playlistId) {
      if (episodeIndex == 0) return ep0File;
      if (episodeIndex == 1) return ep1File;
      return null; // 越界安全拒绝。
    }
    return null;
  }

  @override
  Future<File?> resolveVideoSubtitle(String id,
      {String langCode = 'ja', int episodeIndex = 0}) async {
    if (id == videoId) return subtitleFile;
    if (id == playlistId && episodeIndex == 1) return ep1SubFile;
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

  final Map<String, RemoteBookProgress> bookProgress =
      <String, RemoteBookProgress>{};

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      bookProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    final RemoteBookProgress current =
        bookProgress[bookKey] ?? RemoteBookProgress.empty;
    bookProgress[bookKey] =
        resolveBookProgressSync(local: current, remote: progress);
  }

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
  Future<bool> audiobookExists(String bookKey) async => false;

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

  // ── video position（真实内存实现，TODO-653 端点往返测试用）──────────────────
  final Map<String, ({int positionMs, int updatedAtMs})> videoPositions =
      <String, ({int positionMs, int updatedAtMs})>{};

  static String _posKey(String id, int episodeIndex) =>
      episodeIndex <= 0 ? id : '$id#ep$episodeIndex';

  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      videoPositions[_posKey(id, episodeIndex)] ??
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    final String key = _posKey(id, episodeIndex);
    final ({int positionMs, int updatedAtMs}) current =
        videoPositions[key] ?? (positionMs: 0, updatedAtMs: 0);
    videoPositions[key] = resolveVideoPositionSync(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs < 0 ? 0 : positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
  }
}

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  late _EmbeddedSubtitleFfmpegBackend ffmpeg;
  const String token = 'test-token-video';
  late String base;
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    ffmpeg = _EmbeddedSubtitleFfmpegBackend();
    setFfmpegBackendForTesting(ffmpeg);
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

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    await server.stop();
  });

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

  test('GET /api/library/videos exposes and serves video covers', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest listReq =
        await c.getUrl(Uri.parse('$base/api/library/videos'));
    listReq.headers.set('authorization', authHeader());
    final HttpClientResponse listRes = await listReq.close();
    expect(listRes.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await listRes.transform(utf8.decoder).join())
            as List<dynamic>;
    final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
    expect(first['hasCover'], true);
    final Uri coverUri = Uri.parse(first['coverUrl'] as String);

    final HttpClientRequest coverReq = await c.getUrl(coverUri);
    coverReq.headers.set('authorization', authHeader());
    final HttpClientResponse coverRes = await coverReq.close();
    expect(coverRes.statusCode, 200);
    expect(coverRes.headers.contentType?.mimeType, 'image/png');
    final List<int> body = await coverRes.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) {
        acc.addAll(chunk);
        return acc;
      },
    );
    expect(body, _coverBytes);
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
    expect(json['subtitleFileName'], 'sample.ja.ass',
        reason: '远端字幕协议必须保留 sidecar 扩展名，客户端才不会按 .srt 误解析');
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

  test(
      'GET /api/library/videos/<id>/streamurl exposes embedded subtitle tracks',
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

    final List<dynamic> tracks =
        json['embeddedSubtitleTracks'] as List<dynamic>;
    expect(tracks, hasLength(3));
    final Map<String, dynamic> subrip =
        (tracks[0] as Map).cast<String, dynamic>();
    final Map<String, dynamic> movText =
        (tracks[1] as Map).cast<String, dynamic>();
    final Map<String, dynamic> pgs = (tracks[2] as Map).cast<String, dynamic>();

    expect(subrip['streamIndex'], 0);
    expect(subrip['codec'], 'subrip');
    expect(subrip['isText'], isTrue);
    expect(subrip['url'], contains('embeddedStreamIndex=0'));
    expect(subrip['fileName'], endsWith('.srt'));
    expect(movText['codec'], 'mov_text');
    expect(movText['fileName'], endsWith('.srt'));
    expect(pgs['codec'], 'hdmv_pgs_subtitle');
    expect(pgs['isText'], isFalse);
    expect(pgs.containsKey('url'), isFalse);
    c.close();
  });

  test('GET /api/library/videos/<id>/subtitle extracts embedded text subtitle',
      () async {
    final HttpClient c = HttpClient();
    final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
    final Uri subtitleUri = Uri.parse(
      '$base/api/library/videos/$encodedId/subtitle?embeddedStreamIndex=0',
    );
    final HttpClientRequest req = await c.getUrl(subtitleUri);
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();

    expect(res.statusCode, 200);
    final String body = await res.transform(utf8.decoder).join();
    expect(body, contains('Remote embedded subtitle'));
    expect(ffmpeg.extractedSubtitleIndices, contains(0));
    expect(ffmpeg.extractedSubtitleIndices, contains(1),
        reason: 'remote extraction should reuse the all-text-track demux path');
    c.close();
  });

  test('GET embedded graphical subtitle returns 404 instead of fake text',
      () async {
    final HttpClient c = HttpClient();
    final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
    final Uri subtitleUri = Uri.parse(
      '$base/api/library/videos/$encodedId/subtitle?embeddedStreamIndex=2',
    );
    final HttpClientRequest req = await c.getUrl(subtitleUri);
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();

    expect(res.statusCode, 404);
    await res.drain<void>();
    c.close();
  });

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
    expect(res.headers.contentType?.mimeType, 'text/plain');
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

  // ── video position（TODO-653 跨设备进度同步端点往返）──────────────────────────

  Future<int> putPosition(int positionMs, int updatedAtMs) async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.putUrl(
      Uri.parse('$base/api/library/videos/video%2Fsample/position'),
    );
    req.headers.set('authorization', authHeader());
    req.headers.set('content-type', 'application/json');
    req.write(jsonEncode(<String, Object?>{
      'positionMs': positionMs,
      'positionUpdatedAtMs': updatedAtMs,
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    c.close();
    return res.statusCode;
  }

  Future<Map<String, dynamic>> getPosition() async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(
      Uri.parse('$base/api/library/videos/video%2Fsample/position'),
    );
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    c.close();
    return json;
  }

  test('GET position 初始无记录返回 0/0', () async {
    final Map<String, dynamic> json = await getPosition();
    expect(json['positionMs'], 0);
    expect(json['positionUpdatedAtMs'], 0);
  });

  test('PUT 进度 → GET 读回同值（跨设备往返）', () async {
    expect(await putPosition(600000, 1700000000000), 200);
    final Map<String, dynamic> json = await getPosition();
    expect(json['positionMs'], 600000, reason: 'A 设备写入的进度应在 host 落定');
    expect(json['positionUpdatedAtMs'], 1700000000000);
  });

  test('PUT 较新时间戳覆盖；较旧时间戳被拒（取较新者）', () async {
    expect(await putPosition(600000, 1700000000000), 200);
    // 较新上报覆盖。
    expect(await putPosition(900000, 1700000005000), 200);
    Map<String, dynamic> json = await getPosition();
    expect(json['positionMs'], 900000);
    expect(json['positionUpdatedAtMs'], 1700000005000);
    // 较旧的滞后上报（来自落后设备）不得回退已存的新进度。
    expect(await putPosition(120000, 1699999990000), 200);
    json = await getPosition();
    expect(json['positionMs'], 900000, reason: '旧时间戳不应回退新进度');
    expect(json['positionUpdatedAtMs'], 1700000005000);
  });

  test('PUT 未知视频 id 返回 404（不写脏 prefs）', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.putUrl(
      Uri.parse('$base/api/library/videos/video%2Fmissing/position'),
    );
    req.headers.set('authorization', authHeader());
    req.headers.set('content-type', 'application/json');
    req.write(jsonEncode(<String, Object?>{
      'positionMs': 1000,
      'positionUpdatedAtMs': 1700000000000,
    }));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404, reason: '未知视频 id 应被拒绝');
    await res.drain<void>();
    c.close();
  });

  test('listVideos 带回 host 进度，供 client 跨设备恢复', () async {
    expect(await putPosition(420000, 1700000000000), 200);
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/videos'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
    final Map<dynamic, dynamic> first = json.first as Map<dynamic, dynamic>;
    expect(first['positionMs'], 420000, reason: 'host 进度应随清单条目带回，client 据此恢复');
    expect(first['positionUpdatedAtMs'], 1700000000000);
    c.close();
  });

  // ── TODO-885 per-episode streamurl / subtitle / position ──────────────────
  group('TODO-885 remote playlist per-episode', () {
    String enc(String id) => Uri.encodeFull(id);

    Future<Map<String, dynamic>> streamUrlForEpisode(
      HttpClient c,
      int episode,
    ) async {
      final HttpClientRequest req = await c.getUrl(Uri.parse(
        '$base/api/library/videos/${enc(_FakeLibraryService.playlistId)}'
        '/streamurl?episode=$episode',
      ));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 200, reason: 'episode $episode streamurl ok');
      return jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
    }

    test('streamurl?episode=N streams that episode file (DB-only lookup)',
        () async {
      final HttpClient c = HttpClient();
      final Map<String, dynamic> j1 = await streamUrlForEpisode(c, 1);
      final String url1 = j1['url'] as String;
      expect(url1, contains('/stream'));
      expect(url1, contains('episode=1'),
          reason: 'stream url must carry the episode index');

      // 拉 ep1 流，断言拿到的是 ep1 的字节（5 字节），不是 ep0。
      final HttpClientRequest streamReq = await c.getUrl(Uri.parse(url1));
      final HttpClientResponse streamRes = await streamReq.close();
      expect(streamRes.statusCode, 200);
      final List<int> body =
          await streamRes.fold(<int>[], (List<int> a, List<int> b) {
        return a..addAll(b);
      });
      expect(body, <int>[20, 21, 22, 23, 24],
          reason: 'episode 1 stream must serve ep1 bytes, not ep0');
      c.close();
    });

    test('streamurl?episode=N exposes that episode sidecar subtitle', () async {
      final HttpClient c = HttpClient();
      final Map<String, dynamic> j1 = await streamUrlForEpisode(c, 1);
      expect(j1['subtitleUrl'], isNotNull,
          reason: 'episode 1 has a sidecar subtitle');
      final Uri subUri = Uri.parse(j1['subtitleUrl'] as String);
      expect(subUri.queryParameters['episode'], '1',
          reason: 'subtitle url must carry the episode index');
      final HttpClientRequest subReq = await c.getUrl(subUri);
      subReq.headers.set('authorization', authHeader());
      final HttpClientResponse subRes = await subReq.close();
      expect(subRes.statusCode, 200);
      final String subBody = await subRes.transform(utf8.decoder).join();
      expect(subBody, contains('ep1 sub'));
      c.close();

      // episode 0 has no sidecar -> no subtitleUrl.
      final HttpClient c2 = HttpClient();
      final Map<String, dynamic> j0 = await streamUrlForEpisode(c2, 0);
      expect(j0['subtitleUrl'], isNull,
          reason: 'episode 0 has no sidecar subtitle');
      c2.close();
    });

    test('out-of-range episode index is rejected (404, no path traversal)',
        () async {
      final HttpClient c = HttpClient();
      final HttpClientRequest req = await c.getUrl(Uri.parse(
        '$base/api/library/videos/${enc(_FakeLibraryService.playlistId)}'
        '/streamurl?episode=99',
      ));
      req.headers.set('authorization', authHeader());
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 404,
          reason: 'unknown episode index must not resolve any file');
      await res.drain<void>();
      c.close();
    });

    test('position?episode=N is isolated per episode', () async {
      final HttpClient c = HttpClient();
      // PUT ep1 position.
      final HttpClientRequest put = await c.putUrl(Uri.parse(
        '$base/api/library/videos/${enc(_FakeLibraryService.playlistId)}'
        '/position?episode=1',
      ));
      put.headers.set('authorization', authHeader());
      put.headers.set('content-type', 'application/json');
      put.write(jsonEncode(<String, Object?>{
        'positionMs': 88000,
        'positionUpdatedAtMs': 1700000000000,
      }));
      final HttpClientResponse putRes = await put.close();
      expect(putRes.statusCode, 200);
      await putRes.drain<void>();

      // GET ep1 -> 88000.
      final HttpClientRequest get1 = await c.getUrl(Uri.parse(
        '$base/api/library/videos/${enc(_FakeLibraryService.playlistId)}'
        '/position?episode=1',
      ));
      get1.headers.set('authorization', authHeader());
      final HttpClientResponse get1Res = await get1.close();
      final Map<String, dynamic> j1 =
          jsonDecode(await get1Res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(j1['positionMs'], 88000);

      // GET ep0 -> still 0 (per-episode isolation).
      final HttpClientRequest get0 = await c.getUrl(Uri.parse(
        '$base/api/library/videos/${enc(_FakeLibraryService.playlistId)}'
        '/position?episode=0',
      ));
      get0.headers.set('authorization', authHeader());
      final HttpClientResponse get0Res = await get0.close();
      final Map<String, dynamic> j0 =
          jsonDecode(await get0Res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(j0['positionMs'], 0,
          reason: 'episode 0 must not inherit episode 1 progress');
      c.close();
    });
  });
}

class _EmbeddedSubtitleFfmpegBackend implements FfmpegBackend {
  final List<int> extractedSubtitleIndices = <int>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    if (args.contains('-hide_banner')) {
      return const FfmpegRunResult(returnCode: 1, output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: subrip (srt) (default)
  Stream #0:2(eng): Subtitle: mov_text (tx3g)
  Stream #0:3(jpn): Subtitle: hdmv_pgs_subtitle
''');
    }

    for (int i = 0; i < args.length - 2; i++) {
      if (args[i] == '-map' && args[i + 1].startsWith('0:s:')) {
        final int index = int.parse(args[i + 1].substring('0:s:'.length));
        extractedSubtitleIndices.add(index);
        final File output = File(args[i + 2]);
        output.parent.createSync(recursive: true);
        output.writeAsStringSync(_subtitleTextFor(output.path, index));
      }
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  String _subtitleTextFor(String outputPath, int index) {
    if (outputPath.toLowerCase().endsWith('.ass')) {
      return '''
[Script Info]
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Remote embedded subtitle $index
''';
    }
    return '''
1
00:00:01,000 --> 00:00:02,000
Remote embedded subtitle $index
''';
  }
}
