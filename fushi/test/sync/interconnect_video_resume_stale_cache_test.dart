/// BUG-4231：互联客户端看过一次 host 的视频后，host 端更新的断点在下次打开时被
/// 忽略——播放器从客户端自己的旧断点续播，随后实时上报（戳 = now）把旧位置写回
/// host、盖掉 host 的新进度（Linux Phase 4：host 50 s 被 22 s 覆盖）。
///
/// 根因：开播位置读的是 `PreferencesRepository` 的内存缓存，而互联 sweep
/// （`InterconnectPlaybackPositionSync._writeLocal`）只写库；sweep 后库里是 host 的
/// 新断点，缓存仍是本机上次看的旧断点。host 清单快照又被缓存住（几十秒到几分钟前），
/// 两份旧数据做 LWW，旧断点胜出。
///
/// 这里用生产接线的真 host（`FushiSyncServer` + `LocalLibraryHostService`）、真互联
/// 客户端后端、真 sweep 与真偏好仓库，走播放页开播用的同一个
/// [resolveRemoteVideoResumeMs]。
library;

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
const String _token = 'video-resume-stale-token';

/// host 时刻：清单快照取到的旧断点 40 s @ t0，客户端看到 20 s @ t1，host 自己
/// 接着看到 50 s @ t2（t0 < t1 < t2，都远在「现在」之前，不触发未来戳截断）。
const int _t0 = 1000;
const int _t1 = 2000;
const int _t2 = 3000;

Future<void> _seedHostVideo(FushiDatabase db, Directory dir) async {
  // 视频进度 PUT 端点要求视频文件在 host 真实存在。
  final File file = File(p.join(dir.path, 'host_long.mp4'))
    ..writeAsBytesSync(<int>[0, 1, 2, 3]);
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: _uid,
      title: 'host_long',
      videoPath: file.path,
    ),
  );
}

/// host 本机播放写断点：与 host 端 `VideoFushiPage._persistPosition` 同样写行
/// 并镜像到远端断点键对。
Future<void> _hostWatches(FushiDatabase hostDb, int positionMs, int at) async {
  await hostDb.updateVideoBookPosition(_uid, positionMs, playedAt: at);
  await hostDb.setPrefTyped<int>(videoRemotePositionPrefKey(_uid), positionMs);
  await hostDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(_uid), at);
}

Future<PlaybackPosition> _hostPosition(FushiDatabase hostDb) async => (
  positionMs: await hostDb.getPrefTyped<int>(
    videoRemotePositionPrefKey(_uid),
    0,
  ),
  updatedAtMs: await hostDb.getPrefTyped<int>(
    videoRemotePositionAtPrefKey(_uid),
    0,
  ),
);

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

/// host 不可达的互联客户端：开播时读 host 断点失败（离线打开）。
class _UnreachableHostBackend extends InterconnectSyncBackend {
  _UnreachableHostBackend()
    : super.withProbe((String url, String token) async => true);

  int positionReads = 0;

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    positionReads++;
    throw const SocketException('host unreachable');
  }
}

/// 客户端在播放页里看到 [positionMs]：与 `VideoFushiPage._persistRemotePosition`
/// 同一写法——经偏好仓库写本地键对（库 + 内存缓存），再走 sweep 同一入口上报。
Future<void> _clientWatches(
  PreferencesRepository prefs,
  InterconnectPlaybackPositionSync sync,
  int positionMs,
  int at,
) async {
  await prefs.setPref(videoRemotePositionEpisodePrefKey(_uid, 0), positionMs);
  await prefs.setPref(videoRemotePositionEpisodeAtPrefKey(_uid, 0), at);
  await sync.reportLive(_uid, (positionMs: positionMs, updatedAtMs: at));
}

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late String base;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('video_resume_stale_');
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
    await _seedHostVideo(hostDb, work);
    await _hostWatches(hostDb, 40000, _t0);
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  /// 客户端：打开时取到 host 清单（40 s @ t0，之后不再刷新），看到 20 s @ t1 并
  /// 上报；host 随后接着看到 50 s @ t2。返回客户端库、偏好仓库、后端与清单快照。
  Future<
    ({
      FushiDatabase db,
      PreferencesRepository prefs,
      InterconnectSyncBackend backend,
      PlaybackPosition listed,
    })
  >
  watchOnClientThenOnHost() async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final InterconnectSyncBackend backend = await _clientBackend(base);
    final RemoteVideoInfo info = (await backend.listRemoteVideos()).singleWhere(
      (RemoteVideoInfo v) => v.id == _uid,
    );
    final PlaybackPosition listed = (
      positionMs: info.positionMs,
      updatedAtMs: info.positionUpdatedAtMs,
    );
    expect(listed, (positionMs: 40000, updatedAtMs: _t0));

    final InterconnectPlaybackPositionSync sync =
        InterconnectPlaybackPositionSync(
          db: db,
          backend: backend,
          kind: PlaybackPositionKind.video,
        );
    await _clientWatches(prefs, sync, 20000, _t1);
    expect(await _hostPosition(hostDb), (positionMs: 20000, updatedAtMs: _t1));

    await _hostWatches(hostDb, 50000, _t2);
    return (db: db, prefs: prefs, backend: backend, listed: listed);
  }

  test('sweep 拉到 host 更新的断点后，离线打开也从该断点续播（读库，不读偏好缓存）', () async {
    final (
      :FushiDatabase db,
      :PreferencesRepository prefs,
      :InterconnectSyncBackend backend,
      :PlaybackPosition listed,
    ) = await watchOnClientThenOnHost();

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
    expect(report.conflicts, isEmpty);
    expect(await readLocalRemoteVideoPosition(db, _uid), (
      positionMs: 50000,
      updatedAtMs: _t2,
    ), reason: 'sweep 已把 host 的新断点落进本机库');
    // 根因现场：sweep 只写库，偏好仓库的内存缓存仍是本机自己写的旧断点。读缓存
    // 再与旧清单快照做 LWW，正是修复前的开播判定——得出 20 s。
    expect(prefs.getPref(videoRemotePositionPrefKey(_uid)), 20000);
    expect(
      resolvePositionLww(
        localPositionMs: 20000,
        localUpdatedAtMs: _t1,
        remotePositionMs: listed.positionMs,
        remoteUpdatedAtMs: listed.updatedAtMs,
      ).positionMs,
      20000,
    );

    // 打开时 host 不可达，只剩本机库 + 旧清单快照：仍须从 50 s 续播。
    final _UnreachableHostBackend offline = _UnreachableHostBackend();
    final int resumeMs = await resolveRemoteVideoResumeMs(
      db: db,
      client: offline,
      uid: _uid,
      episodeIndex: 0,
      listed: listed,
    );
    expect(offline.positionReads, 1);
    expect(resumeMs, 50000);
  });

  test('没跑 sweep、清单快照过期：开播问 host 此刻断点，从 host 的新断点续播', () async {
    final (
      :FushiDatabase db,
      prefs: _,
      :InterconnectSyncBackend backend,
      :PlaybackPosition listed,
    ) = await watchOnClientThenOnHost();

    final int resumeMs = await resolveRemoteVideoResumeMs(
      db: db,
      client: backend,
      uid: _uid,
      episodeIndex: 0,
      listed: listed,
    );
    expect(resumeMs, 50000);
    expect(await _hostPosition(hostDb), (
      positionMs: 50000,
      updatedAtMs: _t2,
    ), reason: '开播判定只读，不写 host');
  });

  test('从续播点接着看并实时上报：host 只前进，不被本机旧断点盖回', () async {
    final (
      :FushiDatabase db,
      :PreferencesRepository prefs,
      :InterconnectSyncBackend backend,
      :PlaybackPosition listed,
    ) = await watchOnClientThenOnHost();
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
    await orch.syncVideoProgressLiveForTest(SyncRunReport(), backend);

    final int resumeMs = await resolveRemoteVideoResumeMs(
      db: db,
      client: backend,
      uid: _uid,
      episodeIndex: 0,
      listed: listed,
    );
    expect(resumeMs, 50000);

    // 播放器从续播点走了 2 s 后的那次上报（Phase 4 里这一步把 22 s 写回了 host）。
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await _clientWatches(
      prefs,
      InterconnectPlaybackPositionSync(
        db: db,
        backend: backend,
        kind: PlaybackPositionKind.video,
      ),
      resumeMs + 2000,
      nowMs,
    );
    final PlaybackPosition host = await _hostPosition(hostDb);
    expect(host.positionMs, 52000);
    expect(host.positionMs, greaterThan(50000));
  });

  test('播放页不再从偏好缓存读远端断点（守卫）', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'prefsRepo\.getPref\(\s*videoRemotePositionEpisode(At)?PrefKey',
      ).hasMatch(src),
      isFalse,
      reason: '远端断点有只写库的写者（互联 sweep / 冲突弹窗），读缓存会拿到旧值',
    );
    expect(src, contains('resolveRemoteVideoResumeMs('));
  });
}
