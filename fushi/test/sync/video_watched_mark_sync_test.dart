/// 手动「标记已看 / 未看」× 互联全量同步：真 host（LocalLibraryHostService +
/// FushiSyncServer）+ 真 client 后端 + 真编排器。
///
/// 焊死两件事：
/// 1. 本机标已看 / 取消已看后，下一次同步**不会**把 host 上的旧断点灌回来（标记
///    与 `clearWatchProgress` 同一套盖戳纪律）；
/// 2. 看完标记本身跨设备收敛（`VideoPlaybackSyncState.completedAt` 逐字段 LWW），
///    两台设备不各留一份「已看」真相。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_watched_marks.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _uid = 'video/ep1';
const int _oldPositionMs = 15 * 60 * 1000;

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late FushiDatabase localDb;
  late String base;
  const String token = 'watched-mark-sync-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('watched_mark_sync_');
    hostDb = _memDb();
    localDb = _memDb();
    final LocalLibraryHostService libSvc = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
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

    // 两端都有这一集，都停在同一个中途断点（上次同步已对齐）。
    final File file = File(p.join(work.path, 'ep1.mp4'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    await hostDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _uid,
        title: 'EP1',
        videoPath: file.path,
        lastPositionMs: const Value(_oldPositionMs),
      ),
    );
    await hostDb.setPrefTyped<int>(
      videoRemotePositionPrefKey(_uid),
      _oldPositionMs,
    );
    await hostDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(_uid), 5000);
    await localDb.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: _uid,
        title: 'EP1',
        videoPath: '/tmp/ep1.mp4',
        lastPositionMs: const Value(_oldPositionMs),
      ),
    );
    await localDb.setPrefTyped<int>(
      videoRemotePositionPrefKey(_uid),
      _oldPositionMs,
    );
    await localDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(_uid), 5000);
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    await localDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  Future<void> syncOnce() async {
    final FushiDatabase clientCfg = _memDb();
    addTearDown(clientCfg.close);
    final SyncRepository repo = SyncRepository(clientCfg);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(token);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    final Directory tmp = await Directory(
      p.join(work.path, 'tmp_${DateTime.now().microsecondsSinceEpoch}'),
    ).create();
    final SyncOrchestrator orch = SyncOrchestrator(
      db: localDb,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );
    await orch.syncVideoProgressLiveForTest(SyncRunReport(), backend);
  }

  test('本机标已看 → 同步后断点不被 host 旧值灌回，host 也收到「已看 + 断点 0」', () async {
    await setVideosWatched(
      db: localDb,
      watched: true,
      localUids: <String>[_uid],
    );

    await syncOnce();

    final VideoBookRow local = (await localDb.getVideoBookByBookUid(_uid))!;
    expect(local.lastPositionMs, 0, reason: 'host 的旧中途断点不得灌回来');
    expect(local.completedAt, isNotNull);
    final VideoBookRow host = (await hostDb.getVideoBookByBookUid(_uid))!;
    expect(host.completedAt, isNotNull, reason: '看完标记推到 host（同一份真相）');
    expect(
      host.completedAt!.millisecondsSinceEpoch,
      local.completedAt!.millisecondsSinceEpoch,
    );
    expect(
      await hostDb.getPrefTyped<int>(videoRemotePositionPrefKey(_uid), -1),
      0,
    );

    // 再同步一轮：两端已收敛，状态不抖动。
    await syncOnce();
    final VideoBookRow again = (await localDb.getVideoBookByBookUid(_uid))!;
    expect(again.lastPositionMs, 0);
    expect(again.completedAt, isNotNull);
  });

  test('本机取消已看 → host 上的旧「已看」不会被同步回来', () async {
    // 两端原本都已看（host 那次标记带戳，早于本机这次取消）。
    await VideoBookRepository(hostDb).setWatched(
      <String>[_uid],
      watched: true,
      now: DateTime.fromMillisecondsSinceEpoch(6000),
    );
    await VideoBookRepository(localDb).setWatched(
      <String>[_uid],
      watched: true,
      now: DateTime.fromMillisecondsSinceEpoch(6000),
    );

    await setVideosWatched(
      db: localDb,
      watched: false,
      localUids: <String>[_uid],
    );
    await syncOnce();

    expect((await localDb.getVideoBookByBookUid(_uid))!.completedAt, isNull);
    expect(
      (await hostDb.getVideoBookByBookUid(_uid))!.completedAt,
      isNull,
      reason: '取消已看推到 host',
    );
  });

  test('另一端（host）标已看 → client 同步后跟上，断点同样收回', () async {
    await VideoBookRepository(hostDb).setWatched(<String>[_uid], watched: true);

    await syncOnce();

    final VideoBookRow local = (await localDb.getVideoBookByBookUid(_uid))!;
    expect(local.completedAt, isNotNull);
    expect(local.lastPositionMs, 0);
  });
}
