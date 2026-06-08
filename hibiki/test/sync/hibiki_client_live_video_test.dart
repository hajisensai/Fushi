import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
    subtitleFile = File('${tmp.path}/sample.ja.srt');
    subtitleFile.writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nテスト\n');
  }

  static const String videoId = 'video/sample';
  static final List<int> _videoBytes = List<int>.generate(16, (int i) => i);

  late final File videoFile;
  late final File subtitleFile;

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
  Future<File?> resolveVideoFile(String id) async =>
      id == videoId ? videoFile : null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja'}) async =>
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
}

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

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
  const String token = 'live-video-token';

  setUp(() async {
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

  tearDown(() async => server.stop());

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
    final File dest = File('${tmp.path}/sample.ja.srt');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await backend.getRemoteVideoSubtitle(_FakeLibraryService.videoId, dest);

    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), contains('テスト'));
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
}
