/// BUG-4236：视频页远端卡的「看到 X」只显示 host 清单快照。清单经
/// `RemoteLibraryCache`（TTL）缓存、页面常驻；互联 sweep 把 host 更新的断点落进
/// 本机库、或本机刚看完回来，卡片仍是旧值（Linux Phase 4 r4-13：host 已到 0:50，
/// 卡片「看到 0:40」）。开播位置（BUG-4231）早已认本机库断点，卡片与实际续播对不上。
///
/// 修复：卡片断点 = 清单快照与本机库断点取较新（[withLocalRemoteVideoPositions]，
/// 与开播判定共用 [newestRemoteVideoPosition]）；本机断点一变就发信号
/// （[watchLocalRemoteVideoPositionsChanged]）让页面重算。这里用真 host
/// （`FushiSyncServer` + `LocalLibraryHostService`）、真互联后端与真 sweep。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/remote_video_resume.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _uid = 'video/ext/327d9c4da932';
const String _token = 'video-watched-label-token';

/// 清单快照 40 s @ t0；客户端看到 20 s @ t1；host 接着看到 50 s @ t2。
const int _t0 = 1000;
const int _t1 = 2000;
const int _t2 = 3000;

Future<void> _hostWatches(FushiDatabase hostDb, int positionMs, int at) async {
  await hostDb.updateVideoBookPosition(_uid, positionMs, playedAt: at);
  await hostDb.setPrefTyped<int>(videoRemotePositionPrefKey(_uid), positionMs);
  await hostDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(_uid), at);
}

Future<InterconnectSyncBackend> _clientBackend(String base) async {
  final FushiDatabase authDb = _memDb();
  addTearDown(authDb.close);
  final SyncRepository repo = SyncRepository(authDb);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(_token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String u, String t) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

/// host 不可达的互联客户端（离线开播只剩本机库 + 清单快照）。
class _UnreachableHostBackend extends InterconnectSyncBackend {
  _UnreachableHostBackend()
    : super.withProbe((String url, String token) async => true);

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => throw const SocketException('host unreachable');
}

/// 收集 [stream] 的事件数；[settle] 让 drift 的表级通知与重查跑完。
Future<int Function()> _countEvents(Stream<void> stream) async {
  int count = 0;
  final StreamSubscription<void> sub = stream.listen((_) => count++);
  addTearDown(sub.cancel);
  await _settle();
  return () => count;
}

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late String base;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('video_watched_label_');
    hostDb = _memDb();
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: _token,
      allowLan: false,
      libraryService: LocalLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      ),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    final File file = File(p.join(work.path, 'host_long.mp4'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    await hostDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _uid,
        title: 'host_long',
        videoPath: file.path,
      ),
    );
    await _hostWatches(hostDb, 40000, _t0);
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('sweep 拉到 host 新断点后，缓存的旧清单条目显示新断点，且与开播位置一致', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final InterconnectSyncBackend backend = await _clientBackend(base);
    // 页面拿到的清单快照（之后一直被缓存）。
    final RemoteVideoInfo cached = (await backend.listRemoteVideos())
        .singleWhere((RemoteVideoInfo v) => v.id == _uid);
    expect(cached.positionMs, 40000);

    // 客户端看到 20 s 并上报；host 接着看到 50 s；客户端跑一轮 sweep。
    final InterconnectPlaybackPositionSync sync =
        InterconnectPlaybackPositionSync(
          db: db,
          backend: backend,
          kind: PlaybackPositionKind.video,
        );
    await prefs.setPref(videoRemotePositionEpisodePrefKey(_uid, 0), 20000);
    await prefs.setPref(videoRemotePositionEpisodeAtPrefKey(_uid, 0), _t1);
    await sync.reportLive(_uid, (positionMs: 20000, updatedAtMs: _t1));
    await _hostWatches(hostDb, 50000, _t2);
    final SyncOrchestrator orch = SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );
    final SyncRunReport report = SyncRunReport();
    await orch.syncVideoProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');

    // 修复前卡片直接显示清单快照：40 s。
    final RemoteVideoInfo shown = (await withLocalRemoteVideoPositions(
      db,
      <RemoteVideoInfo>[cached],
    )).single;
    expect(shown.positionMs, 50000);
    expect(shown.positionUpdatedAtMs, _t2);
    expect(shown.id, cached.id);
    expect(shown.title, cached.title);

    // 卡片显示的就是离线开播会续播的位置（同一份判定）。
    final int resumeMs = await resolveRemoteVideoResumeMs(
      db: db,
      client: _UnreachableHostBackend(),
      uid: _uid,
      episodeIndex: 0,
      listed: (
        positionMs: cached.positionMs,
        updatedAtMs: cached.positionUpdatedAtMs,
      ),
    );
    expect(resumeMs, shown.positionMs);
  });

  test('清单比本机库新：条目原样返回（同一对象）；本机无记录也原样返回', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    const RemoteVideoInfo listed = RemoteVideoInfo(
      id: _uid,
      title: 'host_long',
      positionMs: 50000,
      positionUpdatedAtMs: _t2,
    );
    const RemoteVideoInfo other = RemoteVideoInfo(
      id: 'video/other',
      title: 'other',
      positionMs: 7000,
      positionUpdatedAtMs: _t0,
    );
    expect(
      identical(
        (await withLocalRemoteVideoPositions(db, <RemoteVideoInfo>[
          listed,
        ])).single,
        listed,
      ),
      isTrue,
    );

    await db.setPrefTyped<int>(videoRemotePositionPrefKey(_uid), 20000);
    await db.setPrefTyped<int>(videoRemotePositionAtPrefKey(_uid), _t1);
    final List<RemoteVideoInfo> shown = await withLocalRemoteVideoPositions(
      db,
      <RemoteVideoInfo>[listed, other],
    );
    expect(identical(shown[0], listed), isTrue, reason: 'host 的断点更新');
    expect(identical(shown[1], other), isTrue, reason: '本机没看过这一条');
  });

  test('host 播放列表：按 host 当前集的本机按集断点比较', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    const RemoteVideoInfo playlist = RemoteVideoInfo(
      id: 'video/pl',
      title: 'playlist',
      positionMs: 10000,
      positionUpdatedAtMs: _t0,
      currentEpisode: 2,
      episodes: <RemoteVideoEpisode>[
        RemoteVideoEpisode(index: 0, title: 'e1'),
        RemoteVideoEpisode(index: 1, title: 'e2'),
        RemoteVideoEpisode(index: 2, title: 'e3'),
      ],
    );
    // 整书键（第 0 集）更新但不是 host 当前集：不采用。
    await db.setPrefTyped<int>(videoRemotePositionPrefKey('video/pl'), 99000);
    await db.setPrefTyped<int>(videoRemotePositionAtPrefKey('video/pl'), _t2);
    expect(
      (await withLocalRemoteVideoPositions(db, <RemoteVideoInfo>[
        playlist,
      ])).single.positionMs,
      10000,
    );
    await db.setPrefTyped<int>(
      videoRemotePositionEpisodePrefKey('video/pl', 2),
      33000,
    );
    await db.setPrefTyped<int>(
      videoRemotePositionEpisodeAtPrefKey('video/pl', 2),
      _t1,
    );
    expect(
      (await withLocalRemoteVideoPositions(db, <RemoteVideoInfo>[
        playlist,
      ])).single.positionMs,
      33000,
    );
  });

  test('本机远端断点信号：sweep 直接写库、偏好仓库写入都发；别的偏好不发', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final InterconnectSyncBackend backend = await _clientBackend(base);
    await prefs.setPref(videoRemotePositionEpisodePrefKey(_uid, 0), 20000);
    await prefs.setPref(videoRemotePositionEpisodeAtPrefKey(_uid, 0), _t1);
    await db.setSyncBaseline(_uid, kInterconnectVideoPositionDimension, 20000);
    await _hostWatches(hostDb, 50000, _t2);

    final int Function() events = await _countEvents(
      watchLocalRemoteVideoPositionsChanged(db),
    );
    expect(events(), 0, reason: '首次查询只登记基线');

    await db.setPrefTyped<String>('some_unrelated_pref', 'x');
    await _settle();
    expect(events(), 0, reason: '别的偏好写入不发');

    // 互联 sweep 只写库（不经偏好仓库）。
    final SyncOrchestrator orch = SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );
    final SyncRunReport report = SyncRunReport();
    await orch.syncVideoProgressLiveForTest(report, backend);
    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(report.videoPositionsReceived, 1);
    await _settle();
    final int afterSweep = events();
    expect(afterSweep, greaterThanOrEqualTo(1), reason: 'sweep 落地 host 断点');

    // 播放页经偏好仓库写断点（看完回来时最后一次落盘）。
    await prefs.setPref(videoRemotePositionEpisodePrefKey(_uid, 0), 61000);
    await prefs.setPref(videoRemotePositionEpisodeAtPrefKey(_uid, 0), _t2 + 1);
    await _settle();
    expect(events(), greaterThan(afterSweep), reason: '播放页写断点');
  });
}
