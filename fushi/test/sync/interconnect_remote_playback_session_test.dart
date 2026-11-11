/// BUG-4436：远端视频开播按 LWW 选位置，绕过三方判定（含合集切成员）。
///
/// 真 [FushiSyncServer] + [LocalLibraryHostService] + 真 [InterconnectSyncBackend]，
/// 按播放页的调用形态驱动 [InterconnectRemotePlaybackSession]：每一集载入时
/// [InterconnectRemotePlaybackSession.startPositionFor] 与 sweep 走同一份三方判定，
/// 之后的实时上报经同一个会话。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _videoUid = 'vid-remote-session';
const String _memberUid = 'vid-remote-session-member-2';

/// 计数到达 host 的 live 位置 PUT。
class _CountingHost extends LocalLibraryHostService {
  _CountingHost({
    required super.db,
    required super.dictionaryResourceRoot,
    required super.packages,
    required super.refreshDictionaryCache,
    required super.runExclusive,
  });

  int puts = 0;

  @override
  Future<LivePositionWriteOutcome> putVideoPositionChecked(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
    List<int>? expectedPositionsMs,
  }) {
    puts++;
    return super.putVideoPositionChecked(
      id,
      positionMs,
      updatedAtMs,
      episodeIndex: episodeIndex,
      expectedPositionsMs: expectedPositionsMs,
    );
  }
}

PlaybackPosition _pos(int positionMs, int updatedAtMs) =>
    (positionMs: positionMs, updatedAtMs: updatedAtMs);

void main() {
  late Directory work;
  late FushiSyncServer server;
  late bool serverRunning;
  late FushiDatabase hostDb;
  late _CountingHost host;
  late FushiDatabase clientDb;
  late InterconnectSyncBackend backend;
  late InterconnectRemotePlaybackSession session;
  const String token = 'remote-session-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('remote_session_');
    hostDb = _memDb();
    host = _CountingHost(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    for (final String uid in <String>[_videoUid, _memberUid]) {
      final File f = File(p.join(work.path, '$uid.mp4'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      await hostDb.upsertVideoBook(
        VideoBooksCompanion.insert(bookUid: uid, title: uid, videoPath: f.path),
      );
    }
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: host,
    );
    await server.start();
    serverRunning = true;
    clientDb = _memDb();
    final SyncRepository repo = SyncRepository(clientDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(token);
    backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    session = InterconnectRemotePlaybackSession(db: clientDb, backend: backend);
  });

  tearDown(() async {
    session.close();
    if (serverRunning) await server.stop();
    await hostDb.close();
    await clientDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  InterconnectPlaybackPositionSync videoSync() =>
      InterconnectPlaybackPositionSync(
        db: clientDb,
        backend: backend,
        kind: PlaybackPositionKind.video,
      );

  Future<void> setLocal(String uid, int pos, int at) async {
    await clientDb.setPrefTyped<int>(videoRemotePositionPrefKey(uid), pos);
    await clientDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), at);
  }

  Future<PlaybackPosition> local(String uid) => videoSync().localPosition(uid);

  Future<int> hostPos(String uid) async =>
      (await host.getVideoPosition(uid)).positionMs;

  test('真分叉：开播从本机位置起播，本次播放不向 host 上报、冲突留给弹窗', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 两端上次在 10000 一致；之后 host 被另一台设备推到 25000（戳较旧），本机看到
    // 40000（戳较新）。
    await host.putVideoPosition(_videoUid, 10000, now - 120000);
    await videoSync().recordBaseline(_videoUid, 10000);
    await host.putVideoPosition(_videoUid, 25000, now - 60000);
    await setLocal(_videoUid, 40000, now - 1000);

    // 对照：今天的开播判定（LWW）选本机 40000，之后的上报会把 host 推进——两端的
    // 改动里 host 那份被静默覆盖。
    expect(
      resolvePositionLww(
        localPositionMs: 40000,
        localUpdatedAtMs: now - 1000,
        remotePositionMs: 25000,
        remoteUpdatedAtMs: now - 60000,
      ).positionMs,
      40000,
    );

    expect(await session.startPositionFor(_videoUid, fallback: () => 7), 40000);
    final int putsAfterStart = host.puts;

    await session.report(_videoUid, _pos(45000, now));
    await session.report(_videoUid, _pos(46000, now + 1000));

    expect(await hostPos(_videoUid), 25000, reason: 'host 那份改动不被覆盖');
    expect(await videoSync().baseline(_videoUid), 10000);
    expect(host.puts, putsAfterStart, reason: '冲突未裁决前不打注定被拒的 PUT');
  });

  test('冲突裁决后恢复上报：弹窗选对端（基线 = host）→ 下一次上报推进 host', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 120000);
    await videoSync().recordBaseline(_videoUid, 10000);
    await host.putVideoPosition(_videoUid, 25000, now - 60000);
    await setLocal(_videoUid, 40000, now - 1000);

    expect(await session.startPositionFor(_videoUid, fallback: () => 7), 40000);
    await session.report(_videoUid, _pos(41000, now));
    expect(await hostPos(_videoUid), 25000);

    // 模拟冲突弹窗选「对端」：两端在 25000 一致。
    await videoSync().recordBaseline(_videoUid, 25000);
    final int putsBefore = host.puts;
    await session.report(_videoUid, _pos(26000, now + 2000));

    expect(host.puts, greaterThan(putsBefore));
    expect(await hostPos(_videoUid), 26000);
    expect(await videoSync().baseline(_videoUid), 26000);
  });

  test('单边：本机停在基线、host 前进（戳因时钟差反而更旧）→ 从 host 位置起播并落到本机', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 120000);
    await videoSync().recordBaseline(_videoUid, 10000);
    // 另一台时钟偏慢的设备把 host 推到 30000，戳比本机上次写的还旧。
    await setLocal(_videoUid, 10000, now - 5000);
    await host.putVideoPosition(_videoUid, 30000, now - 60000);

    // 对照：LWW 按戳会选本机的 10000，把另一台设备看过的进度丢掉。
    expect(
      resolvePositionLww(
        localPositionMs: 10000,
        localUpdatedAtMs: now - 5000,
        remotePositionMs: 30000,
        remoteUpdatedAtMs: (await host.getVideoPosition(_videoUid)).updatedAtMs,
      ).positionMs,
      10000,
    );

    expect(await session.startPositionFor(_videoUid, fallback: () => 7), 30000);
    expect((await local(_videoUid)).positionMs, 30000);
    expect(await videoSync().baseline(_videoUid), 30000);

    await session.report(_videoUid, _pos(35000, now));
    expect(await hostPos(_videoUid), 35000);
    expect(await videoSync().baseline(_videoUid), 35000);
  });

  test('合集第二个成员首播：无基线、host 无此位置 → 从回退值起播，之后上报到达 host', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;

    expect(await session.startPositionFor(_memberUid, fallback: () => 0), 0);

    await setLocal(_memberUid, 12000, now);
    await session.report(_memberUid, _pos(12000, now));

    expect(await hostPos(_memberUid), 12000);
    expect(await videoSync().baseline(_memberUid), 12000);
  });

  test('离线：host 不可达 → 返回回退值、不抛', () async {
    await setLocal(_videoUid, 40000, DateTime.now().millisecondsSinceEpoch);
    await server.stop();
    serverRunning = false;

    expect(
      await session.startPositionFor(_videoUid, fallback: () => 4321),
      4321,
    );
  });

  // 评审 perf-1：回退值惰性求值——判定读到 host 时不算回退值（播放页的回退值要读库、
  // 此前还会再问一次 host，离线时两轮超时串行），读 host 失败才算、只算一次。
  test('回退值只在判定读 host 失败时求值，且只求一次', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 120000);
    await videoSync().recordBaseline(_videoUid, 10000);
    await setLocal(_videoUid, 10000, now - 5000);
    int fallbackCalls = 0;
    int countingFallback() {
      fallbackCalls++;
      return 4321;
    }

    expect(
      await session.startPositionFor(_videoUid, fallback: countingFallback),
      10000,
    );
    expect(fallbackCalls, 0, reason: '判定成功不求回退值');

    await server.stop();
    serverRunning = false;
    expect(
      await session.startPositionFor(_videoUid, fallback: countingFallback),
      4321,
    );
    expect(fallbackCalls, 1);
  });

  // 评审 tests-2：applyRemote 判定后本机又写了更新的断点（CAS 未落地）→ 从重读的
  // 本机位置起播，不拿 host 的旧值把本机刚写的断点回退。
  test('单边判成落地 host、但判定后本机断点被改写（CAS 未落地）→ 从重读的本机位置起播', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final _CasHookDb hookDb = _CasHookDb();
    addTearDown(hookDb.close);
    final InterconnectPlaybackPositionSync hookSync =
        InterconnectPlaybackPositionSync(
          db: hookDb,
          backend: backend,
          kind: PlaybackPositionKind.video,
        );
    await host.putVideoPosition(_videoUid, 10000, now - 120000);
    await hookSync.recordBaseline(_videoUid, 10000);
    await hookDb.setPrefTyped<int>(
      videoRemotePositionPrefKey(_videoUid),
      10000,
    );
    await hookDb.setPrefTyped<int>(
      videoRemotePositionAtPrefKey(_videoUid),
      now - 5000,
    );
    await host.putVideoPosition(_videoUid, 30000, now - 60000);
    // 本机播放器恰在落地前写进 50000（比较后写入的那一刻）。
    hookDb.beforeCas = () async {
      await hookDb.setPrefTyped<int>(
        videoRemotePositionPrefKey(_videoUid),
        50000,
      );
      await hookDb.setPrefTyped<int>(
        videoRemotePositionAtPrefKey(_videoUid),
        now,
      );
    };
    final InterconnectRemotePlaybackSession hookSession =
        InterconnectRemotePlaybackSession(db: hookDb, backend: backend);
    addTearDown(hookSession.close);

    expect(
      await hookSession.startPositionFor(_videoUid, fallback: () => 7),
      50000,
    );
    expect(hookDb.casCalls, 1);
    expect((await hookSync.localPosition(_videoUid)).positionMs, 50000);
    expect(await hookSync.baseline(_videoUid), 10000, reason: '没落地就不记基线');
  });

  // 评审 tests-2：开播时会话已换 host → 回退值起播，并换绑到新 host（下一次开播按
  // 新 host 判定，不再拿旧 host 的作用域一直抛）。
  test('开播时会话已换 host：返回回退值，并换绑到新 host，下一次开播照常判定', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 先绑到当前 host（老条目作用域）。
    expect(await session.startPositionFor(_memberUid, fallback: () => 0), 0);
    backend.debugSwitchHostScope('b');
    await host.putVideoPosition(_videoUid, 30000, now - 60000);

    expect(
      await session.startPositionFor(_videoUid, fallback: () => 1234),
      1234,
    );
    // 换绑后按新 host（作用域 b，无基线、本机无记录）判定：落地 host 的 30000。
    expect(
      await session.startPositionFor(_videoUid, fallback: () => 1234),
      30000,
    );
    expect(
      await clientDb.getSyncBaseline(
        _videoUid,
        remoteScopedKey(
          kInterconnectVideoPositionDimension,
          syncRemoteTag('fushiServer\nb'),
        ),
      ),
      30000,
    );
  });

  // 评审 compat-3：held 时上报器不发请求，此前也就从不核对 host——会话换了 host
  // 之后仍拿旧 host 作用域的基线短路，新 host 一直收不到这段播放的位置。
  test('held 中会话换了 host：上报器换绑，按新 host 的作用域重新判定这次上报', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 120000);
    await videoSync().recordBaseline(_videoUid, 10000);
    await host.putVideoPosition(_videoUid, 25000, now - 60000);
    await setLocal(_videoUid, 40000, now - 1000);
    expect(await session.startPositionFor(_videoUid, fallback: () => 7), 40000);
    final int putsHeld = host.puts;
    await session.report(_videoUid, _pos(41000, now));
    expect(host.puts, putsHeld, reason: '同一台 host 上仍 held');

    // 会话故障切换到 hostId b（新 host 上该视频停在 41000，与本机一致）。
    backend.debugSwitchHostScope('b');
    await host.putVideoPosition(_videoUid, 41000, now + 500);
    await setLocal(_videoUid, 41000, now + 500);
    await session.report(_videoUid, _pos(41000, now + 500));

    final String scopedB = remoteScopedKey(
      kInterconnectVideoPositionDimension,
      syncRemoteTag('fushiServer\nb'),
    );
    expect(
      await clientDb.getSyncBaseline(_videoUid, scopedB),
      41000,
      reason: '换绑后按新 host 判定（两端一致 → 记基线），不再被旧 held 短路',
    );
    // 旧 host 作用域的基线不动。
    expect(
      await clientDb.getSyncBaseline(
        _videoUid,
        kInterconnectVideoPositionDimension,
      ),
      10000,
    );
  });

  group('remoteEpisodeStartUsesThreeWay', () {
    test('首开 / 换集 / 自动连播 / 合集切成员都判', () {
      for (final EpisodeStartIntent intent in <EpisodeStartIntent>[
        EpisodeStartIntent.initialOpen,
        EpisodeStartIntent.manualPrevious,
        EpisodeStartIntent.manualNext,
        EpisodeStartIntent.listSelect,
        EpisodeStartIntent.autoAdvance,
      ]) {
        expect(
          remoteEpisodeStartUsesThreeWay(
            episodeIndex: 0,
            intent: intent,
            sourceReviewActive: false,
          ),
          isTrue,
          reason: intent.name,
        );
      }
    });

    test('显式起点（换画质 / 换线路）、卡片回看、host-playlist 非首集不判', () {
      expect(
        remoteEpisodeStartUsesThreeWay(
          episodeIndex: 0,
          intent: EpisodeStartIntent.explicitCue,
          sourceReviewActive: false,
        ),
        isFalse,
      );
      expect(
        remoteEpisodeStartUsesThreeWay(
          episodeIndex: 0,
          intent: EpisodeStartIntent.initialOpen,
          sourceReviewActive: true,
        ),
        isFalse,
      );
      expect(
        remoteEpisodeStartUsesThreeWay(
          episodeIndex: 2,
          intent: EpisodeStartIntent.initialOpen,
          sourceReviewActive: false,
        ),
        isFalse,
      );
    });
  });
}

/// 在「比较后写入」之前插一段写入的数据库（模拟本机播放器恰在落地前写断点）。
class _CasHookDb extends FushiDatabase {
  _CasHookDb() : super.forTesting(DatabaseConnection(NativeDatabase.memory()));

  Future<void> Function()? beforeCas;
  int casCalls = 0;

  @override
  Future<bool> runIfIntPrefUnchanged({
    required String stampKey,
    required int expectedStamp,
    required Future<void> Function() write,
  }) async {
    casCalls++;
    final Future<void> Function()? hook = beforeCas;
    beforeCas = null;
    if (hook != null) await hook();
    return super.runIfIntPrefUnchanged(
      stampKey: stampKey,
      expectedStamp: expectedStamp,
      write: write,
    );
  }
}
