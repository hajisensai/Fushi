import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/tls/hibiki_tls_identity.dart';
import 'package:fushi_core/fushi_core.dart';

const List<int> _coverBytes = <int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4];

class _FakeLibraryService implements FushiLibraryHostService {
  // BUG-1004：host 端裁 mining 句子音频（本测试不涉及，返 null 即可）。
  @override
  Future<File?> clipVideoAudio(String id,
          {required int startMs,
          required int endMs,
          int episodeIndex = 0,
          int? audioStreamIndex,
          int? audioStreamCount,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async =>
      null;

  @override
  Future<List<RemoteActivityEvent>> listActivityEvents(
          {int limit = 100}) async =>
      const <RemoteActivityEvent>[];

  @override
  Future<String?> videoCoverPath(String id) async {
    for (final RemoteVideoInfo v in await listVideos()) {
      if (v.id == id) return v.coverPath;
    }
    return null;
  }

  @override
  Future<String?> bookCoverPath(String id) async {
    for (final RemoteBookInfo b in await listBooks()) {
      if (b.downloadId == id || b.title == id) return b.coverPath;
    }
    return null;
  }

  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {}

  @override
  Future<CollectionManifest> getCollectionManifest() async =>
      CollectionManifest.empty;

  @override
  Future<CollectionManifest> mergeCollectionManifest(
          CollectionManifest incoming) async =>
      incoming;

  _FakeLibraryService() {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_client_vid');
    videoFile = File('${tmp.path}/sample.mp4');
    videoFile.writeAsBytesSync(_videoBytes);
    videoFile.setLastModifiedSync(_uniqueSubtitleCacheMtime(tmp.path));
    subtitleFile = File('${tmp.path}/sample.ja.vtt');
    subtitleFile.writeAsStringSync(
      'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nテスト\n',
    );
    coverFile = File('${tmp.path}/cover.png')..writeAsBytesSync(_coverBytes);
  }

  static const String videoId = 'video/sample';
  static final List<int> _videoBytes = List<int>.generate(16, (int i) => i);

  late final File videoFile;
  late final File subtitleFile;
  late final File coverFile;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async {
    final ({int positionMs, int updatedAtMs}) p =
        await getVideoPosition(videoId);
    return <RemoteVideoInfo>[
      RemoteVideoInfo(
        id: videoId,
        title: 'Sample Video',
        sizeBytes: 16,
        hasSubtitle: true,
        coverPath: coverFile.path,
        positionMs: p.positionMs,
        positionUpdatedAtMs: p.updatedAtMs,
      ),
    ];
  }

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == videoId ? videoFile : null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja', int episodeIndex = 0}) async =>
      id == videoId ? subtitleFile : null;

  /// 记录 client→host 上传（供上传端点 e2e 断言）。
  final List<({String id, String title, String? fileName, List<int> bytes})>
      uploaded =
      <({String id, String title, String? fileName, List<int> bytes})>[];

  @override
  Future<bool> videoExists(String id) async =>
      id == videoId || uploaded.any((u) => u.id == id);

  @override
  Future<void> importVideoSubtitle(File subtitleFile,
      {required String id, required String suffix}) async {}

  @override
  Future<void> importVideo(File videoFile,
      {required String id,
      required String title,
      String? originalFileName}) async {
    uploaded.add((
      id: id,
      title: title,
      fileName: originalFileName,
      bytes: await videoFile.readAsBytes(),
    ));
  }

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

  final Map<String, ({int positionMs, int updatedAtMs})> videoPositions =
      <String, ({int positionMs, int updatedAtMs})>{};

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
      videoPositions[id] ?? (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    final ({int positionMs, int updatedAtMs}) current =
        videoPositions[id] ?? (positionMs: 0, updatedAtMs: 0);
    videoPositions[id] = resolvePositionLww(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs < 0 ? 0 : positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
  }
}

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

DateTime _uniqueSubtitleCacheMtime(String seed) {
  final int offsetMs = seed.hashCode & 0x3fffffff;
  return DateTime.fromMillisecondsSinceEpoch(1700000000000 + offsetMs);
}

Future<InterconnectSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _testDb();
  addTearDown(() async => db.close());
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);

  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String url, String tok) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  late FushiSyncServer server;
  late String base;
  late _EmbeddedSubtitleFfmpegBackend ffmpeg;
  late _FakeLibraryService library;
  const String token = 'live-video-token';

  setUp(() async {
    ffmpeg = _EmbeddedSubtitleFfmpegBackend();
    setFfmpegBackendForTesting(ffmpeg);
    library = _FakeLibraryService();
    server = FushiSyncServer(
      syncDataDir:
          Directory.systemTemp.createTempSync('hbk_live_video_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: library,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    await server.stop();
  });

  test('listRemoteVideos returns host video entries', () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final List<RemoteVideoInfo> result = await backend.listRemoteVideos();

    expect(result, hasLength(1));
    expect(result.single.id, _FakeLibraryService.videoId);
    expect(result.single.title, 'Sample Video');
    expect(result.single.sizeBytes, 16);
    expect(result.single.hasSubtitle, isTrue);
  });

  test('putRemoteVideo uploads local video file to host (client→host)',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_up');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // 非 ASCII 文件名 + 标题：验证 header URL-encode 往返（HTTP header 只收 ASCII）。
    final File local = File('${tmp.path}/映画.mp4')
      ..writeAsBytesSync(<int>[10, 20, 30, 40, 50]);

    await backend.putRemoteVideo('video/uploaded', local, title: '映画タイトル');

    expect(library.uploaded, hasLength(1));
    final ({String id, String title, String? fileName, List<int> bytes}) rec =
        library.uploaded.single;
    expect(rec.id, 'video/uploaded'); // 含 `/` 的 bookUid 经 _encodeVideoId 往返
    expect(rec.title, '映画タイトル'); // 非 ASCII 标题经 header 往返正确
    expect(rec.fileName, '映画.mp4'); // 原始文件名保留（供 host 保扩展名）
    expect(rec.bytes, <int>[10, 20, 30, 40, 50]); // 字节流完整送达
  });

  test('remoteVideoStreamUrls returns directly playable token stream URL',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final RemoteVideoStreamUrls urls =
        await backend.remoteVideoStreamUrls(_FakeLibraryService.videoId);

    expect(urls.streamUrl, startsWith('$base/api/library/videos/'));
    expect(urls.streamUrl, contains('/stream?token='));
    expect(urls.subtitleUrl, startsWith('$base/api/library/videos/'));
    expect(urls.subtitleUrl, contains('/subtitle'));
    expect(urls.subtitleFileName, 'sample.ja.vtt');
    expect(urls.embeddedSubtitleTracks, hasLength(3));
    expect(urls.embeddedSubtitleTracks[0].streamIndex, 0);
    expect(
      urls.embeddedSubtitleTracks[0].url,
      contains('embeddedStreamIndex=0'),
    );
    expect(urls.embeddedSubtitleTracks[1].codec, 'mov_text');
    expect(urls.embeddedSubtitleTracks[2].isText, isFalse);
    expect(backend.remoteVideoAuthHeaders(), isEmpty);

    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(Uri.parse(urls.streamUrl));
    req.headers.set('range', 'bytes=0-3');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 206);
    expect(res.headers.value('content-range'), 'bytes 0-3/16');
    final List<int> body = await res.fold(<int>[], (List<int> a, List<int> b) {
      return a..addAll(b);
    });
    expect(body, <int>[0, 1, 2, 3]);
    c.close();
  });

  test('getRemoteVideoSubtitle downloads sidecar subtitle with Basic auth',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_sub');
    final File dest = File('${tmp.path}/sample.ja.vtt');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteVideoSubtitle(_FakeLibraryService.videoId, dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), contains('テスト'));
  });

  test(
      'getRemoteVideoSubtitle downloads embedded text subtitle with Basic auth',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_embsub');
    final File dest = File('${tmp.path}/sample.embedded.srt');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteVideoSubtitle(
      _FakeLibraryService.videoId,
      dest,
      embeddedStreamIndex: 0,
    );

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), contains('Remote embedded subtitle'));
    expect(ffmpeg.extractedSubtitleIndices, contains(0));
  });

  test('downloadRemoteVideo streams video bytes to destination file', () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_dl');
    final File dest = File('${tmp.path}/sample.mp4');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.downloadRemoteVideo(_FakeLibraryService.videoId, dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsBytesSync(), List<int>.generate(16, (int i) => i));
  });

  test('listRemoteVideos with wrong token throws SyncAuthError', () async {
    final FushiDatabase db = _testDb();
    addTearDown(() async => db.close());
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setHibikiClientToken('wrong-token');

    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);

    await expectLater(
      backend.listRemoteVideos(),
      throwsA(isA<SyncAuthError>()),
    );
  });

  test('putRemoteVideoPosition uploads then remoteVideoPosition reads it back',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);

    await backend.putRemoteVideoPosition(
      _FakeLibraryService.videoId,
      600000,
      1700000000000,
    );

    final ({int positionMs, int updatedAtMs}) read =
        await backend.remoteVideoPosition(_FakeLibraryService.videoId);
    expect(read.positionMs, 600000);
    expect(read.updatedAtMs, 1700000000000);

    // 进度也随清单条目带回（client 据此跨设备恢复）。
    final List<RemoteVideoInfo> list = await backend.listRemoteVideos();
    expect(list.single.positionMs, 600000);
    expect(list.single.positionUpdatedAtMs, 1700000000000);
  });

  test('remoteVideoPosition for unknown id returns 0/0 (host 404, no throw)',
      () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final ({int positionMs, int updatedAtMs}) read =
        await backend.remoteVideoPosition('video/does-not-exist');
    expect(read.positionMs, 0);
    expect(read.updatedAtMs, 0);
  });

  // ── TODO-1235（TODO-961 回归）：封面走互联同款钉扎客户端 ─────────────────────
  // Image.network 走 Flutter 内部 HttpClient，拿不到 TOFU 钉扎指纹，https 自签握手
  // 必失败 → 空封面。这里端到端证明 fetchRemoteCover 复用 pinned client 能拉回封面。
  group('TODO-1235 pinned cover fetch over TLS', () {
    late FushiSyncServer tlsServer;
    late String tlsBase;
    late String fingerprint;

    setUp(() async {
      final ({String certificatePem, String privateKeyPem}) cert =
          FushiSelfSignedCertGenerator.generate(
        commonName: 'hibiki-test',
        sanIpAddresses: <String>['127.0.0.1'],
      );
      fingerprint = FushiTlsIdentityStore.fingerprintOf(cert.certificatePem);
      final SecurityContext ctx = SecurityContext()
        ..useCertificateChainBytes(cert.certificatePem.codeUnits)
        ..usePrivateKeyBytes(cert.privateKeyPem.codeUnits);
      tlsServer = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_tls_cover').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: _FakeLibraryService(),
        securityContext: ctx,
        hostFingerprint: fingerprint,
      );
      await tlsServer.start();
      tlsBase = 'https://127.0.0.1:${tlsServer.port}';
    });

    tearDown(() async => tlsServer.stop());

    Future<InterconnectSyncBackend> buildPinnedBackend(String? fp) async {
      final FushiDatabase db = _testDb();
      addTearDown(() async => db.close());
      final SyncRepository repo = SyncRepository(db);
      await repo.setHibikiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: tlsBase, enabled: true, fingerprintSha256: fp),
      ]);
      await repo.setHibikiClientToken(token);
      final InterconnectSyncBackend backend =
          InterconnectSyncBackend.withProbe((String u, String t) async => true);
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      return backend;
    }

    test('fetchRemoteCover pulls cover bytes over pinned https', () async {
      final InterconnectSyncBackend backend =
          await buildPinnedBackend(fingerprint);
      final List<RemoteVideoInfo> videos = await backend.listRemoteVideos();
      final String? coverUrl = videos.single.coverUrl;
      expect(coverUrl, isNotNull, reason: 'host 应回填 https coverUrl');
      expect(coverUrl, startsWith('https://'),
          reason: 'TLS 开启时封面 URL 必须是 https');

      final Uint8List bytes = await backend.fetchRemoteCover(coverUrl!);
      expect(bytes, _coverBytes, reason: '钉扎客户端应握手成功并拉回真封面字节');
    });

    test('cover fetch with wrong fingerprint is rejected by pinning', () async {
      final String wrongFp = fingerprint.startsWith('00:')
          ? '11:${fingerprint.substring(3)}'
          : '00:${fingerprint.substring(3)}';
      // 错误指纹下，钉扎在地址解析的 TLS 探测阶段就拒绝（reachability 失败），或退一
      // 步在 fetchRemoteCover 握手时拒绝——两处都是钉扎生效，故把整条链一起断言抛出，
      // 证明「绝不放行任意自签证书」。
      Future<Uint8List> attempt() async {
        final InterconnectSyncBackend backend =
            await buildPinnedBackend(wrongFp);
        return backend.fetchRemoteCover(
          '$tlsBase/api/library/videos/video%2Fsample/cover',
        );
      }

      await expectLater(attempt(), throwsA(anything),
          reason: '指纹不符必须被钉扎拒绝，绝不放行任意自签证书');
    });
  });

  test('fetchRemoteCover still works over plaintext http (老路径零破坏)', () async {
    final InterconnectSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final List<RemoteVideoInfo> videos = await backend.listRemoteVideos();
    final String? coverUrl = videos.single.coverUrl;
    expect(coverUrl, isNotNull);
    expect(coverUrl, startsWith('http://'));
    final Uint8List bytes = await backend.fetchRemoteCover(coverUrl!);
    expect(bytes, _coverBytes);
  });
}

class _EmbeddedSubtitleFfmpegBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '{"format":{}}');

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
        output.writeAsStringSync('''
1
00:00:01,000 --> 00:00:02,000
Remote embedded subtitle $index
''');
      }
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}
