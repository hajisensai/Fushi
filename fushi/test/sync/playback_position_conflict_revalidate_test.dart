/// BUG-4279：播放进度冲突弹窗按「用户看到的对端值」落地。真 [FushiSyncServer] +
/// [LocalLibraryHostService] + 真 [InterconnectSyncBackend]（`playback_position_conflict_test.dart`
/// 里有 testWidgets，测试绑定会把 HttpClient 换成恒回 400 的假客户端，所以真 host
/// 用例单独成文件）。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/playback_position_conflict_dialog.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart' show SyncChoice;
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

void main() {
  /// BUG-4279：弹窗按「用户看到的对端值」落地。真 [FushiSyncServer] + 真
  /// [InterconnectSyncBackend]：选本机推送锁内重读的本端（弹窗期间本机播放推进是
  /// 常态），前置条件是弹窗展示的对端值；选对端时 host 已不是展示的值就不落地。
  group('applyPlaybackPositionDecisions 按展示的对端值落地（真 host）', () {
    const String uid = 'vid-dialog-revalidate';
    const String token = 'pos-dialog-revalidate-token';
    late Directory work;
    late FushiDatabase hostDb;
    late LocalLibraryHostService host;
    late FushiSyncServer server;
    late FushiDatabase clientDb;
    late InterconnectSyncBackend backend;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('pos_dialog_revalidate_');
      hostDb = _memDb();
      host = LocalLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      final File f = File(p.join(work.path, 'v.mp4'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      await hostDb.upsertVideoBook(
        VideoBooksCompanion.insert(bookUid: uid, title: 'V', videoPath: f.path),
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
      await server.stop();
      await hostDb.close();
      await clientDb.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    Future<void> setLocal(int pos, int at) async {
      await clientDb.setPrefTyped<int>(videoRemotePositionPrefKey(uid), pos);
      await clientDb.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), at);
    }

    /// 基线 1000、host 3000、本机 2000：两端都偏离基线 → 冲突视图。
    Future<List<PlaybackPositionConflictView>> loadConflict(int now) async {
      await clientDb.setSyncBaseline(
        uid,
        kInterconnectVideoPositionDimension,
        1000,
      );
      await host.putVideoPosition(uid, 3000, now - 1000);
      await setLocal(2000, now - 2000);
      final List<PlaybackPositionConflictView> views =
          await loadPlaybackPositionConflicts(
            db: clientDb,
            backend: backend,
            conflicts: <SyncConflict>[
              SyncConflict(
                assetKey: uid,
                dimension: kInterconnectVideoPositionDimension,
                title: 'V',
              ),
            ],
          );
      expect(views, hasLength(1));
      expect(views.single.remote.positionMs, 3000);
      return views;
    }

    test('选本机：弹窗期间本机播放又推进 → 推送推进后的本机值并算解决', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final List<PlaybackPositionConflictView> views = await loadConflict(now);
      // 用户思考期间本机继续播放。
      await setLocal(2500, now);

      final int applied = await applyPlaybackPositionDecisions(
        views,
        <int, SyncChoice>{0: SyncChoice.useLocal},
      );

      expect(applied, 1);
      expect((await host.getVideoPosition(uid)).positionMs, 2500);
      expect(
        await clientDb.getSyncBaseline(
          uid,
          kInterconnectVideoPositionDimension,
        ),
        2500,
      );
    });

    test('选对端：弹窗期间 host 又被第三台设备改写 → 不落地、不算解决', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final List<PlaybackPositionConflictView> views = await loadConflict(now);
      await host.putVideoPosition(uid, 4000, now + 60000);

      final int applied = await applyPlaybackPositionDecisions(
        views,
        <int, SyncChoice>{0: SyncChoice.useRemote},
      );

      expect(applied, 0);
      expect(
        await clientDb.getPrefTyped<int>(videoRemotePositionPrefKey(uid), 0),
        2000,
        reason: '用户没见过的对端值不落到本机',
      );
      expect(
        await clientDb.getSyncBaseline(
          uid,
          kInterconnectVideoPositionDimension,
        ),
        1000,
      );
    });
  });
}
