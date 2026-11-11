/// BUG-4431：client 只按 host 确认记基线。真 [FushiSyncServer] +
/// [LocalLibraryHostService] + 真 [InterconnectSyncBackend]：host 拒收 / 判定后被第三
/// 台设备改写时，实时上报、冲突弹窗「保留本机」、书进度推送都不能把基线推进到上报值。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
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

const String _videoUid = 'vid-live-push';
const String _bookKey = 'live-push-book';

Future<void> _seedHostVideo(FushiDatabase db, Directory dir) async {
  final File videoFile = File(p.join(dir.path, 'live_push.mp4'))
    ..writeAsBytesSync(<int>[0, 1, 2, 3]);
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: _videoUid,
      title: 'live push',
      videoPath: videoFile.path,
    ),
  );
}

Future<void> _seedBook(FushiDatabase db) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: _bookKey,
    title: _bookKey,
    epubPath: '/tmp/$_bookKey.epub',
    extractDir: '/tmp/$_bookKey',
    chapterCount: 3,
    chaptersJson: '["a","b","c"]',
    importedAt: 1,
  ),
);

Future<void> _setLocalVideo(FushiDatabase db, int pos, int at) async {
  await db.setPrefTyped<int>(videoRemotePositionPrefKey(_videoUid), pos);
  await db.setPrefTyped<int>(videoRemotePositionAtPrefKey(_videoUid), at);
}

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late LocalLibraryHostService host;
  late FushiDatabase clientDb;
  late InterconnectSyncBackend backend;
  const String token = 'live-push-confirm-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('live_push_confirm_');
    hostDb = _memDb();
    host = LocalLibraryHostService(
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

  InterconnectPlaybackPositionSync videoSync() =>
      InterconnectPlaybackPositionSync(
        db: clientDb,
        backend: backend,
        kind: PlaybackPositionKind.video,
      );

  group('V-C3 reportLive', () {
    test('host 戳更新但仍停在基线上：前置条件命中，不按戳拒收，确认后记基线', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await _seedHostVideo(hostDb, work);
      await host.putVideoPosition(_videoUid, 5000, now + 60000);
      final InterconnectPlaybackPositionSync sync = videoSync();
      await sync.recordBaseline(_videoUid, 5000);
      await _setLocalVideo(clientDb, 8000, now);

      final LiveReportResult result = await sync.reportLive(_videoUid, (
        positionMs: 8000,
        updatedAtMs: now,
      ));

      expect(result, LiveReportResult.confirmed);
      expect((await host.getVideoPosition(_videoUid)).positionMs, 8000);
      expect(await sync.baseline(_videoUid), 8000);
    });

    test('host 已被第三台设备改写：held，基线不动、待确认行删除、host 不被覆盖', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await _seedHostVideo(hostDb, work);
      await host.putVideoPosition(_videoUid, 8000, now);
      final InterconnectPlaybackPositionSync sync = videoSync();
      await sync.recordBaseline(_videoUid, 8000);
      // 第三台设备把 host 推到 Z。
      await host.putVideoPosition(_videoUid, 12000, now + 60000);
      await _setLocalVideo(clientDb, 9000, now + 1);

      final LiveReportResult result = await sync.reportLive(_videoUid, (
        positionMs: 9000,
        updatedAtMs: now + 1,
      ));

      expect(result, LiveReportResult.held);
      expect(await sync.baseline(_videoUid), 8000);
      expect(
        await clientDb.getSyncBaseline(_videoUid, sync.pendingDimension),
        isNull,
      );
      expect((await host.getVideoPosition(_videoUid)).positionMs, 12000);
    });
  });

  test('V-C2 冲突弹窗选本机：展示后 host 又被改写 → 不算解决、基线不变成本机值', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _seedHostVideo(hostDb, work);
    final InterconnectPlaybackPositionSync sync = videoSync();
    await sync.recordBaseline(_videoUid, 1000);
    await host.putVideoPosition(_videoUid, 3000, now - 1000);
    await _setLocalVideo(clientDb, 2000, now - 2000);

    final List<PlaybackPositionConflictView> views =
        await loadPlaybackPositionConflicts(
          db: clientDb,
          backend: backend,
          conflicts: <SyncConflict>[
            SyncConflict(
              assetKey: _videoUid,
              dimension: kInterconnectVideoPositionDimension,
              title: 'live push',
              localVersion: 0,
              remoteVersion: 0,
            ),
          ],
        );
    expect(views, hasLength(1));
    // 用户思考期间第三台设备把 host 推到 Y1。
    await host.putVideoPosition(_videoUid, 4000, now + 60000);

    final int applied = await applyPlaybackPositionDecisions(
      views,
      <int, SyncChoice>{0: SyncChoice.useLocal},
    );

    expect(applied, 0);
    expect(await sync.baseline(_videoUid), 1000);
    expect((await host.getVideoPosition(_videoUid)).positionMs, 4000);
  });

  test('书进度按过期 host 快照推送 → superseded，基线不变、host 不被覆盖', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _seedBook(hostDb);
    await _seedBook(clientDb);
    await host.putBookProgress(
      _bookKey,
      RemoteBookProgress(
        sectionIndex: 1,
        normCharOffset: 10,
        charOffset: 10,
        updatedAtMs: now - 5000,
      ),
    );
    final InterconnectBookProgressSync sync = InterconnectBookProgressSync(
      db: clientDb,
      backend: backend,
    );
    final EpubBookRow book = (await clientDb.getEpubBook(_bookKey))!;
    const BookProgressBaseline base = BookProgressBaseline(
      sectionIndex: 0,
      normCharOffset: 0,
    );
    await clientDb.setSyncBaseline(
      _bookKey,
      kInterconnectBookProgressDimension,
      base.encode(),
    );
    final RemoteBookProgress staleRemote = await sync.remoteProgress(book);
    // 判定之后第三台设备把 host 推到 section 2。
    await host.putBookProgress(
      _bookKey,
      RemoteBookProgress(
        sectionIndex: 2,
        normCharOffset: 20,
        charOffset: 20,
        updatedAtMs: now + 60000,
      ),
    );
    final RemoteBookProgress local = RemoteBookProgress(
      sectionIndex: 0,
      normCharOffset: 50,
      charOffset: 50,
      updatedAtMs: now - 1000,
    );
    await clientDb.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(book.uid),
        sectionIndex: const Value(0),
        normCharOffset: const Value(50),
        charOffset: const Value(50),
        updatedAt: Value(now - 1000),
      ),
    );

    final ({LivePushStatus status, RemoteBookProgress agreed}) pushed =
        await sync.pushLocal(book, local: local, remote: staleRemote);

    expect(pushed.status, LivePushStatus.superseded);
    expect((await sync.baseline(book))?.encode(), base.encode());
    final RemoteBookProgress hostNow = await host.getBookProgress(_bookKey);
    expect(hostNow.sectionIndex, 2);
    expect(hostNow.normCharOffset, 20);
  });
}
