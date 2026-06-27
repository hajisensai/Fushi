import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

class _FakeLibraryService implements HibikiLibraryHostService {
  _FakeLibraryService() {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_client_vid');
    videoFile = File('${tmp.path}/sample.mp4');
    videoFile.writeAsBytesSync(_videoBytes);
    videoFile.setLastModifiedSync(_uniqueSubtitleCacheMtime(tmp.path));
    subtitleFile = File('${tmp.path}/sample.ja.vtt');
    subtitleFile.writeAsStringSync(
      'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nテスト\n',
    );
  }

  static const String videoId = 'video/sample';
  static final List<int> _videoBytes = List<int>.generate(16, (int i) => i);

  late final File videoFile;
  late final File subtitleFile;

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
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

  final Map<String, ({int positionMs, int updatedAtMs})> videoPositions =
      <String, ({int positionMs, int updatedAtMs})>{};

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
    videoPositions[id] = resolveVideoPositionSync(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs < 0 ? 0 : positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
  }
}

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

DateTime _uniqueSubtitleCacheMtime(String seed) {
  final int offsetMs = seed.hashCode & 0x3fffffff;
  return DateTime.fromMillisecondsSinceEpoch(1700000000000 + offsetMs);
}

Future<HibikiClientSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = _testDb();
  addTearDown(() async => db.close());
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);

  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String url, String tok) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  late HibikiSyncServer server;
  late String base;
  late _EmbeddedSubtitleFfmpegBackend ffmpeg;
  const String token = 'live-video-token';

  setUp(() async {
    ffmpeg = _EmbeddedSubtitleFfmpegBackend();
    setFfmpegBackendForTesting(ffmpeg);
    server = HibikiSyncServer(
      syncDataDir:
          Directory.systemTemp.createTempSync('hbk_live_video_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: _FakeLibraryService(),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    await server.stop();
  });

  test('listRemoteVideos returns host video entries', () async {
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final List<RemoteVideoInfo> result = await backend.listRemoteVideos();

    expect(result, hasLength(1));
    expect(result.single.id, _FakeLibraryService.videoId);
    expect(result.single.title, 'Sample Video');
    expect(result.single.sizeBytes, 16);
    expect(result.single.hasSubtitle, isTrue);
  });

  test('remoteVideoStreamUrls returns directly playable token stream URL',
      () async {
    final HibikiClientSyncBackend backend =
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
    final HibikiClientSyncBackend backend =
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
    final HibikiClientSyncBackend backend =
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
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vid_dl');
    final File dest = File('${tmp.path}/sample.mp4');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.downloadRemoteVideo(_FakeLibraryService.videoId, dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsBytesSync(), List<int>.generate(16, (int i) => i));
  });

  test('listRemoteVideos with wrong token throws SyncAuthError', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(() async => db.close());
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<HibikiClientUrl>[
      HibikiClientUrl(url: base, enabled: true),
    ]);
    await repo.setHibikiClientToken('wrong-token');

    final HibikiClientSyncBackend backend =
        HibikiClientSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);

    await expectLater(
      backend.listRemoteVideos(),
      throwsA(isA<SyncAuthError>()),
    );
  });

  test('putRemoteVideoPosition uploads then remoteVideoPosition reads it back',
      () async {
    final HibikiClientSyncBackend backend =
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
    final HibikiClientSyncBackend backend =
        await _buildBackend(base: base, token: token);

    final ({int positionMs, int updatedAtMs}) read =
        await backend.remoteVideoPosition('video/does-not-exist');
    expect(read.positionMs, 0);
    expect(read.updatedAtMs, 0);
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
