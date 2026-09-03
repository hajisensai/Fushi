/// 互联视频文件 live push（client→host）full-sweep 测试。
///
/// 覆盖 [SyncOrchestrator]._syncVideosLive：syncVideoFiles 开启时，本地单文件视频经
/// host 上传端点注册进 host 视频库；流媒体（http 路径）/ 多集播放列表被
/// _isUploadableLocalVideo 跳过；同尺寸幂等（重复 sweep 不重传、不产生重复条目）。
/// 用真实 server/host/client/local，端到端打通 client putRemoteVideo → server PUT
/// 端点 → host importVideo 落库。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<InterconnectSyncBackend> _buildClientBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator({
  required FushiDatabase db,
  required SyncBackend backend,
  required Directory tmp,
}) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncVideoFiles: true,
      syncDictionary: false,
    );

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late Directory hostUploads;
  late String base;
  const String token = 'orch-live-video-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_live_video_');
    hostDb = _memDb();
    hostUploads = Directory(p.join(work.path, 'host_uploads'))
      ..createSync(recursive: true);
    final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      uploadedVideoRoot: hostUploads,
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('本地单文件视频上传到 host；流媒体/播放列表跳过；同尺寸幂等', () async {
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);

    // 可上传：真实本地单文件视频。
    final File localVid = File(p.join(work.path, 'movie.mp4'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    await localDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/movie',
      title: 'Movie',
      videoPath: localVid.path,
    ));
    // 流媒体：http 路径，无本地字节 → _isUploadableLocalVideo 跳过。
    await localDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/stream',
      title: 'Stream',
      videoPath: 'https://example.com/s.m3u8',
    ));
    // 多集播放列表：单文件资产模型装不下 → 跳过。
    await localDb.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/playlist',
      title: 'Playlist',
      videoPath: localVid.path,
      playlistJson:
          const Value<String?>('[{"path":"/a.mp4"},{"path":"/b.mp4"}]'),
    ));

    final InterconnectSyncBackend backend =
        await _buildClientBackend(base: base, token: token);
    final SyncRunReport report =
        await _orchestrator(db: localDb, backend: backend, tmp: work).run();

    // host 只收到可上传的单文件视频，字节完整；流媒体/播放列表未上传。
    final List<VideoBookRow> hostVideos = await hostDb.allVideoBooks();
    expect(hostVideos.map((VideoBookRow v) => v.bookUid).toList(),
        <String>['video/movie']);
    expect(report.videosExported, 1);
    final VideoBookRow hosted = hostVideos.single;
    expect(hosted.title, 'Movie');
    expect(p.isWithin(hostUploads.path, hosted.videoPath), isTrue);
    expect(File(hosted.videoPath).readAsBytesSync(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8]);

    // 幂等：再跑一次 sweep，host 不重复、videosExported 归零（同尺寸跳过）。
    final SyncRunReport report2 =
        await _orchestrator(db: localDb, backend: backend, tmp: work).run();
    expect((await hostDb.allVideoBooks()).length, 1);
    expect(report2.videosExported, 0);
  });
}
