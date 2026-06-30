/// TODO-767 / BUG-417: orchestrator book + video progress live two-way full sweep test.
/// Root cause: interconnect manual-full-sync previously sent book progress only via
/// SyncManager WebDAV file box (progress_*.json); host never applied it into its own
/// reader_positions DB. Video progress only synced on-demand. This test verifies the
/// live host-apply + bidirectional + full-sweep fix with a real server/host/client/local.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<void> _seedBook(HibikiDatabase db, String title) =>
    db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '/tmp/$title.epub',
      extractDir: '/tmp/$title',
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ));

Future<void> _seedPosition(
  HibikiDatabase db,
  String bookKey, {
  required int section,
  required int norm,
  required int charOffset,
  required int updatedAt,
}) =>
    db.upsertReaderPosition(ReaderPositionsCompanion(
      bookKey: Value(bookKey),
      sectionIndex: Value(section),
      normCharOffset: Value(norm),
      charOffset: Value(charOffset),
      updatedAt: Value(updatedAt),
    ));

Future<void> _seedHostVideo(
  HibikiDatabase db,
  Directory dir,
  String uid,
  String title,
) async {
  // 视频进度 PUT 端点要求该视频文件在 host 真实存在（防路径穿越/任意 id 写脏）。
  final File videoFile = File(p.join(dir.path, '$title.mp4'))
    ..writeAsBytesSync(<int>[0, 1, 2, 3]);
  await db.upsertVideoBook(VideoBooksCompanion.insert(
    bookUid: uid,
    title: title,
    videoPath: videoFile.path,
  ));
}

/// 在 host DB 种一本可经 live-sync 列出的有声书：Audiobooks 行 + SrtBooks 行齐备
/// （host listAudiobooks 要求两表同源，缺一不列出，见 AppModelLibraryHostService）。
Future<void> _seedHostAudiobook(HibikiDatabase db, String bookKey) async {
  await db.upsertAudiobook(AudiobooksCompanion.insert(
    bookKey: bookKey,
    alignmentFormat: 'srt',
    alignmentPath: '/tmp/$bookKey.srt',
  ));
  await db.upsertSrtBook(SrtBooksCompanion.insert(
    uid: 'srt-$bookKey',
    title: bookKey,
    bookKey: Value(bookKey),
    srtPath: '/tmp/$bookKey.srt',
    importedAt: 0,
  ));
}

Future<HibikiClientSyncBackend> _buildClientBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator({
  required HibikiDatabase db,
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
      syncDictionary: false,
      syncLocalAudio: false,
    );

void main() {
  late Directory work;
  late HibikiSyncServer server;
  late HibikiDatabase hostDb;
  late String base;
  const String token = 'orch-live-progress-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_live_progress_');
    hostDb = _memDb();
    final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    server = HibikiSyncServer(
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

  group('book progress full sweep', () {
    test('local has progress, host none -> push to host DB (host-apply)',
        () async {
      // host 也有这本书（真实互联场景：syncContent 已把内容推成 host 书，或两端
      // 各自有同名书）——putBookProgress 的书存在性闸门要求 host 书库先有该书。
      await _seedBook(hostDb, 'BookA');
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await _seedBook(localDb, 'BookA');
      await _seedPosition(localDb, 'BookA',
          section: 4, norm: 4200, charOffset: 88, updatedAt: 2000);

      final Directory tmp = Directory(p.join(work.path, 't1'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      final SyncRunReport report = SyncRunReport();
      await orch.syncBookProgressLiveForTest(report, backend);
      expect(report.errors, isEmpty, reason: '${report.errors}');

      final ReaderPositionRow? hostRow =
          await hostDb.getReaderPosition('BookA');
      expect(hostRow, isNotNull);
      expect(hostRow!.sectionIndex, 4);
      expect(hostRow.normCharOffset, 4200);
      expect(hostRow.updatedAt, 2000);
    });

    test('host newer progress, local old -> apply to local (newer-wins)',
        () async {
      await _seedPosition(hostDb, 'BookB',
          section: 9, norm: 9000, charOffset: 90, updatedAt: 5000);

      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await _seedBook(localDb, 'BookB');
      await _seedPosition(localDb, 'BookB',
          section: 1, norm: 100, charOffset: 1, updatedAt: 1000);

      final Directory tmp = Directory(p.join(work.path, 't2'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncBookProgressLiveForTest(SyncRunReport(), backend);

      final ReaderPositionRow? localRow =
          await localDb.getReaderPosition('BookB');
      expect(localRow!.sectionIndex, 9);
      expect(localRow.updatedAt, 5000);
    });

    test('local newer not rolled back by host old', () async {
      await _seedBook(hostDb, 'BookC');
      await _seedPosition(hostDb, 'BookC',
          section: 1, norm: 10, charOffset: 1, updatedAt: 1000);

      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await _seedBook(localDb, 'BookC');
      await _seedPosition(localDb, 'BookC',
          section: 7, norm: 7000, charOffset: 70, updatedAt: 9000);

      final Directory tmp = Directory(p.join(work.path, 't3'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncBookProgressLiveForTest(SyncRunReport(), backend);

      final ReaderPositionRow? localRow =
          await localDb.getReaderPosition('BookC');
      expect(localRow!.sectionIndex, 7);
      final ReaderPositionRow? hostRow =
          await hostDb.getReaderPosition('BookC');
      expect(hostRow!.sectionIndex, 7);
      expect(hostRow.updatedAt, 9000);
    });
  });

  group('video progress full sweep', () {
    test('local has lastPositionMs, host none -> push to host video prefs',
        () async {
      await _seedHostVideo(hostDb, work, 'video/v1', 'V1');
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/v1',
        title: 'V1',
        videoPath: '/tmp/v1.mp4',
        lastPositionMs: const Value(600000),
      ));
      await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/v1'), 3000);

      final Directory tmp = Directory(p.join(work.path, 'tv1'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncVideoProgressLiveForTest(SyncRunReport(), backend);

      final int hostPos = await hostDb.getPrefTyped<int>(
          videoRemotePositionPrefKey('video/v1'), 0);
      expect(hostPos, 600000);
      final int hostAt = await hostDb.getPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/v1'), 0);
      expect(hostAt, 3000);
    });

    test('host newer video progress -> apply to local lastPositionMs',
        () async {
      await _seedHostVideo(hostDb, work, 'video/v2', 'V2');
      await hostDb.setPrefTyped<int>(
          videoRemotePositionPrefKey('video/v2'), 1200000);
      await hostDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/v2'), 8000);

      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/v2',
        title: 'V2',
        videoPath: '/tmp/v2.mp4',
        lastPositionMs: const Value(100000),
      ));
      await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/v2'), 2000);

      final Directory tmp = Directory(p.join(work.path, 'tv2'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncVideoProgressLiveForTest(SyncRunReport(), backend);

      final VideoBookRow? row = await localDb.getVideoBookByBookUid('video/v2');
      expect(row!.lastPositionMs, 1200000);
    });

    test('streamed video (prefs only, no local VideoBooks row) pushes to host',
        () async {
      // client 流式看远端视频：本地无 VideoBooks 行，只有 resume 路径写的
      // video_remote_position_<uid> + _at_<uid> prefs（断点①回归）。
      await _seedHostVideo(hostDb, work, 'video/stream', 'Stream');
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.setPrefTyped<int>(
          videoRemotePositionPrefKey('video/stream'), 720000);
      await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/stream'), 5000);

      final Directory tmp = Directory(p.join(work.path, 'tvs'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncVideoProgressLiveForTest(SyncRunReport(), backend);

      final int hostPos = await hostDb.getPrefTyped<int>(
          videoRemotePositionPrefKey('video/stream'), 0);
      expect(hostPos, 720000,
          reason: 'streamed video progress must enter host via full sweep');
      // 写回不得为流式视频强建 VideoBooks 行（避免污染书架）。
      final VideoBookRow? localRow =
          await localDb.getVideoBookByBookUid('video/stream');
      expect(localRow, isNull,
          reason: 'sweep must not create a VideoBooks row for streamed video');
    });

    test('streamed video receives newer host progress into prefs (no row)',
        () async {
      await _seedHostVideo(hostDb, work, 'video/stream2', 'Stream2');
      await hostDb.setPrefTyped<int>(
          videoRemotePositionPrefKey('video/stream2'), 990000);
      await hostDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/stream2'), 9000);

      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.setPrefTyped<int>(
          videoRemotePositionPrefKey('video/stream2'), 100000);
      await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/stream2'), 2000);

      final Directory tmp = Directory(p.join(work.path, 'tvs2'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncVideoProgressLiveForTest(SyncRunReport(), backend);

      final int localPos = await localDb.getPrefTyped<int>(
          videoRemotePositionPrefKey('video/stream2'), 0);
      expect(localPos, 990000,
          reason: 'host-newer streamed progress must write back to prefs');
      final int localAt = await localDb.getPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/stream2'), 0);
      expect(localAt, 9000);
      final VideoBookRow? localRow =
          await localDb.getVideoBookByBookUid('video/stream2');
      expect(localRow, isNull);
    });
  });

  group('audiobook progress full sweep (BUG-471)', () {
    test('local has audiobook position, host none -> push to host prefs',
        () async {
      await _seedHostAudiobook(hostDb, 'AB1');
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.setPrefTyped<int>(audiobookPositionPrefKey('AB1'), 480000);
      await localDb.setPrefTyped<int>(audiobookPositionAtPrefKey('AB1'), 3000);

      final Directory tmp = Directory(p.join(work.path, 'ta1'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      final SyncRunReport report = SyncRunReport();
      await orch.syncAudiobookProgressLiveForTest(report, backend);
      expect(report.errors, isEmpty, reason: '${report.errors}');

      expect(await hostDb.getPrefTyped<int>(audiobookPositionPrefKey('AB1'), 0),
          480000);
      expect(
          await hostDb.getPrefTyped<int>(audiobookPositionAtPrefKey('AB1'), 0),
          3000);
    });

    test('host newer audiobook progress -> apply to local prefs', () async {
      await _seedHostAudiobook(hostDb, 'AB2');
      await hostDb.setPrefTyped<int>(audiobookPositionPrefKey('AB2'), 990000);
      await hostDb.setPrefTyped<int>(audiobookPositionAtPrefKey('AB2'), 8000);

      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.setPrefTyped<int>(audiobookPositionPrefKey('AB2'), 100000);
      await localDb.setPrefTyped<int>(audiobookPositionAtPrefKey('AB2'), 2000);

      final Directory tmp = Directory(p.join(work.path, 'ta2'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncAudiobookProgressLiveForTest(SyncRunReport(), backend);

      expect(
          await localDb.getPrefTyped<int>(audiobookPositionPrefKey('AB2'), 0),
          990000);
      expect(
          await localDb.getPrefTyped<int>(audiobookPositionAtPrefKey('AB2'), 0),
          8000);
    });

    test('local newer not rolled back by host old', () async {
      await _seedHostAudiobook(hostDb, 'AB3');
      await hostDb.setPrefTyped<int>(audiobookPositionPrefKey('AB3'), 1000);
      await hostDb.setPrefTyped<int>(audiobookPositionAtPrefKey('AB3'), 1000);

      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.setPrefTyped<int>(audiobookPositionPrefKey('AB3'), 700000);
      await localDb.setPrefTyped<int>(audiobookPositionAtPrefKey('AB3'), 9000);

      final Directory tmp = Directory(p.join(work.path, 'ta3'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      await orch.syncAudiobookProgressLiveForTest(SyncRunReport(), backend);

      expect(
          await localDb.getPrefTyped<int>(audiobookPositionPrefKey('AB3'), 0),
          700000);
      expect(await hostDb.getPrefTyped<int>(audiobookPositionPrefKey('AB3'), 0),
          700000,
          reason: 'local newer must propagate to host');
      expect(
          await hostDb.getPrefTyped<int>(audiobookPositionAtPrefKey('AB3'), 0),
          9000);
    });

    test('local has audiobook but host does not -> skip (no error)', () async {
      // host 没有这本有声书：listAudiobooks 不含它 → 跳过，不报错。
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await localDb.setPrefTyped<int>(
          audiobookPositionPrefKey('AB_local_only'), 60000);
      await localDb.setPrefTyped<int>(
          audiobookPositionAtPrefKey('AB_local_only'), 4000);

      final Directory tmp = Directory(p.join(work.path, 'ta4'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      final SyncRunReport report = SyncRunReport();
      await orch.syncAudiobookProgressLiveForTest(report, backend);
      expect(report.errors, isEmpty);
      // host 无该有声书 → 不写脏 prefs。
      expect(
          await hostDb.getPrefTyped<int>(
              audiobookPositionPrefKey('AB_local_only'), 0),
          0);
    });
  });

  group('full run() syncs book + video progress together', () {
    test('interconnect run() runs book + video progress live sweep', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      await _seedHostVideo(hostDb, work, 'video/run', 'VRun');
      await _seedBook(hostDb, 'BookRun');
      await _seedBook(localDb, 'BookRun');
      await _seedHostAudiobook(hostDb, 'ABRun');
      await localDb.setPrefTyped<int>(
          audiobookPositionPrefKey('ABRun'), 360000);
      await localDb.setPrefTyped<int>(
          audiobookPositionAtPrefKey('ABRun'), 4000);
      await _seedPosition(localDb, 'BookRun',
          section: 3, norm: 3000, charOffset: 33, updatedAt: 4000);
      await localDb.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/run',
        title: 'VRun',
        videoPath: '/tmp/vrun.mp4',
        lastPositionMs: const Value(450000),
      ));
      await localDb.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/run'), 4000);

      final Directory tmp = Directory(p.join(work.path, 'trun'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: base, token: token);
      final SyncOrchestrator orch =
          _orchestrator(db: localDb, backend: backend, tmp: tmp);

      final SyncRunReport report = await orch.run();
      expect(report.errors, isEmpty,
          reason: 'run() full sweep no errors: ${report.errors}');

      final ReaderPositionRow? hostBook =
          await hostDb.getReaderPosition('BookRun');
      expect(hostBook, isNotNull);
      expect(hostBook!.sectionIndex, 3);

      final int hostVidPos = await hostDb.getPrefTyped<int>(
          videoRemotePositionPrefKey('video/run'), 0);
      expect(hostVidPos, 450000);

      final int hostAbPos =
          await hostDb.getPrefTyped<int>(audiobookPositionPrefKey('ABRun'), 0);
      expect(hostAbPos, 360000,
          reason: 'run() full sweep must also push audiobook progress to host');
    });
  });
}
