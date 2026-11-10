/// BUG-4279：互联 live 播放位置按旧快照盲写 host。真 [FushiSyncServer] +
/// [LocalLibraryHostService] + 真 [InterconnectSyncBackend]：
/// - 旧判定推送带前置条件，host 已被更新的上报推进时不回退（D7）；
/// - sweep 与实时上报对同一条目按条目锁互斥，两个 PUT 不同时到达 host；
/// - 播放页上报器按条目合并，慢网下不积压、只发最新值；
/// - host 被第三方改写后上报 held、不再每秒打注定被拒的 PUT，裁决后自动恢复。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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

const String _videoUid = 'vid-live-race';

/// 可以把 live 位置写入挂住的 host：[gate] 非 null 时每次 PUT 先等它，并计数
/// 到达 host 的 PUT 与 GET。
class _GatedHost extends LocalLibraryHostService {
  _GatedHost({
    required super.db,
    required super.dictionaryResourceRoot,
    required super.packages,
    required super.refreshDictionaryCache,
    required super.runExclusive,
  });

  Completer<void>? gate;
  int puts = 0;
  int gets = 0;

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) {
    gets++;
    return super.getVideoPosition(id, episodeIndex: episodeIndex);
  }

  @override
  Future<LivePositionWriteOutcome> putVideoPositionChecked(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
    List<int>? expectedPositionsMs,
  }) async {
    puts++;
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    return super.putVideoPositionChecked(
      id,
      positionMs,
      updatedAtMs,
      episodeIndex: episodeIndex,
      expectedPositionsMs: expectedPositionsMs,
    );
  }
}

/// 等到 [cond] 成立（真 HTTP 往返没有可 pump 的假时钟）；5 秒不成立就失败。
Future<void> _until(bool Function() cond) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 5)) {
      fail('condition not reached in time');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

PlaybackPosition _pos(int positionMs, int updatedAtMs) =>
    (positionMs: positionMs, updatedAtMs: updatedAtMs);

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late _GatedHost host;
  late FushiDatabase clientDb;
  late InterconnectSyncBackend backend;
  const String token = 'live-race-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('live_race_');
    hostDb = _memDb();
    host = _GatedHost(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    final File videoFile = File(p.join(work.path, 'race.mp4'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    await hostDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _videoUid,
        title: 'race',
        videoPath: videoFile.path,
      ),
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: host,
    );
    await server.start();
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
  });

  tearDown(() async {
    // 用例中途失败时放行挂住的 PUT；已放行过的 gate 不再 complete。
    final Completer<void>? gate = host.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await server.stop();
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

  Future<void> setLocal(int pos, int at) async {
    await clientDb.setPrefTyped<int>(
      videoRemotePositionPrefKey(_videoUid),
      pos,
    );
    await clientDb.setPrefTyped<int>(
      videoRemotePositionAtPrefKey(_videoUid),
      at,
    );
  }

  Future<int> hostPos() async =>
      (await host.getVideoPosition(_videoUid)).positionMs;

  test('D7：实时上报已推进 host 后，按旧判定推送 → superseded，host 与基线不回退', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 10000);
    final InterconnectPlaybackPositionSync sync = videoSync();
    await sync.recordBaseline(_videoUid, 10000);
    await setLocal(20000, now - 5000);
    // 判定时读到的 host（旧快照）。
    final PlaybackPosition staleRemote = await sync.remotePosition(_videoUid);

    expect(
      await sync.reportLive(_videoUid, _pos(30000, now)),
      LiveReportResult.confirmed,
    );
    expect(await hostPos(), 30000);

    final ({LivePushStatus status, PlaybackPosition agreed}) pushed = await sync
        .pushLocal(
          _videoUid,
          local: _pos(20000, now - 5000),
          remote: staleRemote,
          expectedRemotePositions: <int>[staleRemote.positionMs],
        );

    expect(pushed.status, LivePushStatus.superseded);
    expect(await hostPos(), 30000);
    expect(await sync.baseline(_videoUid), 30000);
  });

  test('互斥：sweep 与实时上报同一条目，第二个 PUT 不在第一个放行前到达 host', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 10000);
    final InterconnectPlaybackPositionSync sync = videoSync();
    await sync.recordBaseline(_videoUid, 10000);
    await setLocal(20000, now - 5000);
    final SyncOrchestrator orch = SyncOrchestrator(
      db: clientDb,
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
    // 先让 client 学到 host 能力（新 host 直接 PUT，不先 GET），PUT 计数只看写。
    await sync.remotePosition(_videoUid);
    host
      ..puts = 0
      ..gate = Completer<void>();

    final SyncRunReport report = SyncRunReport();
    final Future<void> sweep = orch.syncVideoProgressLiveForTest(
      report,
      backend,
    );
    final Future<LiveReportResult> live = sync.reportLive(
      _videoUid,
      _pos(25000, now),
    );
    await _until(() => host.puts >= 1);
    // 给第二个写者足够时间：没有条目锁时它此刻已经到达 host。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(host.puts, 1, reason: '条目锁内只允许一个写者在途');

    host.gate!.complete();
    await sweep;
    await live;
    expect(report.errors, isEmpty);
    expect(await sync.baseline(_videoUid), await hostPos());
  });

  test('上报器：host 写入挂住时连报 20 次，只发在途 + 最新一个；close 后不再发', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 10000);
    final InterconnectPlaybackPositionSync sync = videoSync();
    await sync.recordBaseline(_videoUid, 10000);
    await sync.remotePosition(_videoUid);
    host
      ..puts = 0
      ..gate = Completer<void>();
    final LivePositionReporter reporter = LivePositionReporter(
      db: clientDb,
      backend: backend,
      kind: PlaybackPositionKind.video,
    );

    final List<Future<void>> reports = <Future<void>>[
      for (int i = 1; i <= 20; i++)
        reporter.report(_videoUid, _pos(10000 + i * 1000, now + i)),
    ];
    await _until(() => host.puts >= 1);
    host.gate!.complete();
    host.gate = null;
    await Future.wait(reports);

    expect(host.puts, lessThanOrEqualTo(2));
    expect(await hostPos(), 30000);
    expect(await sync.baseline(_videoUid), 30000);

    reporter.close();
    final int putsBefore = host.puts;
    await reporter.report(_videoUid, _pos(40000, now + 100));
    expect(host.puts, putsBefore);
    expect(await hostPos(), 30000);
  });

  test('上报器：host 被第三方改写 → held 后不再发网络请求，裁决改了基线后恢复上报', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await host.putVideoPosition(_videoUid, 10000, now - 10000);
    final InterconnectPlaybackPositionSync sync = videoSync();
    await sync.recordBaseline(_videoUid, 10000);
    // 第三台设备把 host 推到 50000。
    await host.putVideoPosition(_videoUid, 50000, now + 60000);
    final LivePositionReporter reporter = LivePositionReporter(
      db: clientDb,
      backend: backend,
      kind: PlaybackPositionKind.video,
    );

    await reporter.report(_videoUid, _pos(12000, now));
    expect(await hostPos(), 50000);
    expect(await sync.baseline(_videoUid), 10000);

    final int putsHeld = host.puts;
    final int getsHeld = host.gets;
    await reporter.report(_videoUid, _pos(13000, now + 1));
    await reporter.report(_videoUid, _pos(14000, now + 2));
    expect(host.puts, putsHeld, reason: 'held 期间不打注定被拒的 PUT');
    expect(host.gets, getsHeld, reason: 'held 期间也不读 host');

    // 模拟 sweep / 冲突弹窗裁决：两端在 50000 一致。
    await sync.recordBaseline(_videoUid, 50000);
    await reporter.report(_videoUid, _pos(55000, now + 70000));
    expect(host.puts, greaterThan(putsHeld));
    expect(await hostPos(), 55000);
    expect(await sync.baseline(_videoUid), 55000);
  });

  test('上报器：基线与待确认都为空、host 无此视频位置 → 推送并记基线', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final LivePositionReporter reporter = LivePositionReporter(
      db: clientDb,
      backend: backend,
      kind: PlaybackPositionKind.video,
    );

    await reporter.report(_videoUid, _pos(15000, now));

    expect(await hostPos(), 15000);
    expect(await videoSync().baseline(_videoUid), 15000);
  });
}
