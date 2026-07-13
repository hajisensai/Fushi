import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/cloud_remote_video_client.dart';
import 'package:hibiki/src/sync/obfuscating_sync_backend.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

SyncOrchestrator _orchestrator(
  HibikiDatabase db,
  SyncBackend backend,
  Directory tmp, {
  required bool syncVideoFiles,
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
      syncVideoFiles: syncVideoFiles,
      syncDictionary: false,
      syncLocalAudio: false,
    );

/// Seeds one local-file video book with a real file on disk. Returns its uid.
Future<String> _seedLocalVideo(
  HibikiDatabase db,
  Directory dir, {
  required String uid,
  required String title,
  String contents = 'video-bytes',
  String? coverName,
}) async {
  final File vid = File(p.join(dir.path, '$title.mp4'))
    ..writeAsStringSync(contents);
  String? coverPath;
  if (coverName != null) {
    coverPath = p.join(dir.path, coverName);
    File(coverPath).writeAsBytesSync(<int>[9, 8, 7, 6]);
  }
  await db.upsertVideoBook(VideoBooksCompanion.insert(
    bookUid: uid,
    title: title,
    videoPath: vid.path,
    coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
    importedAt: Value(DateTime.fromMillisecondsSinceEpoch(1000)),
  ));
  return uid;
}

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_video_');
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('SyncRepository sync_video_files switch', () {
    test('defaults OFF and writes through', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.isSyncVideoFilesEnabled(), isFalse,
          reason: 'video upload is opt-in (large files)');

      await repo.setSyncVideoFilesEnabled(true);
      expect(await repo.isSyncVideoFilesEnabled(), isTrue);
      await repo.setSyncVideoFilesEnabled(false);
      expect(await repo.isSyncVideoFilesEnabled(), isFalse);
    });

    test('is NOT device-local (restored with a backup import)', () {
      // Behaviour switch, like sync_audiobook_files — must NOT sit in the
      // device-local key catalog (which a backup import preserves).
      expect(
        SyncRepository.deviceLocalPrefKeys,
        isNot(contains('sync_video_files_enabled')),
      );
    });
  });

  group('reserved folder', () {
    test('__videos__ is a reserved sync folder (never treated as a book)', () {
      expect(isReservedSyncFolderName(kSyncVideosNamespace), isTrue);
    });
  });

  group('syncVideoAssets upload phase', () {
    test('switch OFF via run() uploads nothing', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideo(db, tmp, uid: 'video/Off', title: 'Off');

      await _orchestrator(db, backend, tmp, syncVideoFiles: false).run();

      final List<AssetEntry> children =
          await store.listChildren(kSyncVideosNamespace);
      expect(children.where((AssetEntry e) => !e.isFolder), isEmpty,
          reason: 'gate closed → no video asset, no manifest');
    });

    test('switch ON uploads missing video + writes correct manifest', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final String uid = await _seedLocalVideo(db, tmp,
          uid: 'video/Up', title: 'Up', contents: 'the-real-bytes');

      final SyncRunReport report = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(report);

      expect(report.errors, isEmpty, reason: report.errors.join(' | '));
      expect(report.videosExported, 1);

      // Manifest present with one correct entry.
      final CloudRemoteVideoClient client =
          CloudRemoteVideoClient(backend: store);
      final List<RemoteVideoManifestEntry> entries =
          await client.listRemoteVideos();
      expect(entries.length, 1);
      final RemoteVideoManifestEntry e = entries.single;
      expect(e.uid, uid);
      expect(e.title, 'Up');
      expect(e.sizeBytes, 'the-real-bytes'.length);
      expect(e.importedAtMs, 1000);
      expect(e.coverAsset, isNull);

      // The video file asset really landed and downloads back byte-exact.
      final File dest = File('${tmp.path}/pulled.mp4');
      await client.getRemoteVideo(uid, dest);
      expect(dest.readAsStringSync(), 'the-real-bytes');
    });

    test('re-run is idempotent (same size skipped, manifest byte-stable)',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideo(db, tmp, uid: 'video/Idem', title: 'Idem');

      final SyncRunReport first = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(first);
      expect(first.videosExported, 1);
      final AssetEntry? manifestA =
          await store.findAsset(kSyncVideosNamespace, kSyncVideosManifestName);
      final Object? bytesA = await store.getJsonAsset(manifestA!.id);

      final SyncRunReport second = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(second);
      expect(second.videosExported, 0,
          reason: 'remote already has same-size video → skip upload');
      expect(second.errors, isEmpty);
      final AssetEntry? manifestB =
          await store.findAsset(kSyncVideosNamespace, kSyncVideosManifestName);
      final Object? bytesB = await store.getJsonAsset(manifestB!.id);
      expect(jsonEncode(bytesB), jsonEncode(bytesA),
          reason: 'deterministic manifest → identical bytes across runs');
    });

    test('cover file is uploaded and downloadable by uid', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final String uid = await _seedLocalVideo(db, tmp,
          uid: 'video/Cov', title: 'Cov', coverName: 'cov.jpg');

      final SyncRunReport report = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(report);
      expect(report.errors, isEmpty, reason: report.errors.join(' | '));

      final CloudRemoteVideoClient client =
          CloudRemoteVideoClient(backend: store);
      final RemoteVideoManifestEntry e =
          (await client.listRemoteVideos()).single;
      expect(e.coverAsset, isNotNull);

      final File cover = File('${tmp.path}/pulled_cover.jpg');
      final bool had = await client.getRemoteVideoCover(uid, cover);
      expect(had, isTrue);
      expect(cover.readAsBytesSync(), <int>[9, 8, 7, 6]);
    });

    test('streaming video (URL / streamSpec / playlist) is not uploaded',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // http stream (no local bytes)
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/Stream',
        title: 'Stream',
        videoPath: 'https://example.com/live.m3u8',
        streamSpecJson: const Value('{"referer":"x"}'),
      ));
      // multi-episode playlist (single-file asset model can't represent it)
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/Playlist',
        title: 'Playlist',
        videoPath: p.join(tmp.path, 'ep1.mp4'),
        playlistJson: const Value('[{"title":"ep1","path":"/ep1.mp4"}]'),
      ));

      final SyncRunReport report = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(report);
      expect(report.videosExported, 0);
      expect(report.errors, isEmpty);
      final List<AssetEntry> children =
          await store.listChildren(kSyncVideosNamespace);
      expect(children.where((AssetEntry e) => !e.isFolder), isEmpty,
          reason: 'no uploadable local bytes → nothing published');
    });

    test('upload-only union keeps another device\'s remote-only entry',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // Device B already published a video into the shared manifest.
      await store.putJsonAsset(
        kSyncVideosNamespace,
        kSyncVideosManifestName,
        const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[
          RemoteVideoManifestEntry(
            uid: 'video/FromB',
            title: 'FromB',
            videoAsset: 'video_FromB_00000000.mp4',
            sizeBytes: 42,
          ),
        ]).toJson(),
      );

      // Device A syncs its own local video.
      await _seedLocalVideo(db, tmp, uid: 'video/FromA', title: 'FromA');
      final SyncRunReport report = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(report);
      expect(report.errors, isEmpty, reason: report.errors.join(' | '));

      final Set<String> uids =
          (await CloudRemoteVideoClient(backend: store).listRemoteVideos())
              .map((RemoteVideoManifestEntry e) => e.uid)
              .toSet();
      expect(uids, containsAll(<String>['video/FromA', 'video/FromB']),
          reason: 'upload-only union must not drop the remote-only entry');
    });
  });

  group('adversarial finding fixes', () {
    // finding 1/7：同尺寸跳过判据不能用远端物理尺寸——resolveSyncBackend 无条件包
    // ObfuscatingSyncBackend（远端 = 明文 + 8 字节 magic），且 Dropbox/WebDAV/FTP
    // 不报 sizeBytes。改用清单记录的明文尺寸后，第二轮必须零重传。
    test(
        'finding1/7 idempotent under ObfuscatingSyncBackend (remote size = plaintext+8)',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final SyncBackend backend =
          ObfuscatingSyncBackend(FakeSyncBackend(store));
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideo(db, tmp,
          uid: 'video/Obf', title: 'Obf', contents: 'the-real-bytes');

      final SyncRunReport first = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(first);
      expect(first.videosExported, 1);

      final SyncRunReport second = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(second);
      expect(second.videosExported, 0,
          reason:
              'obfuscated remote size = plaintext+8; skip must use manifest '
              'plaintext size, not physical remote size');
      expect(second.errors, isEmpty);
    });

    test(
        'finding7 idempotent when backend reports null sizeBytes (Dropbox/WebDAV/FTP)',
        () async {
      final FakeAssetStore store = FakeAssetStore(reportNullSizes: true);
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideo(db, tmp, uid: 'video/NullSz', title: 'NullSz');

      final SyncRunReport first = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(first);
      expect(first.videosExported, 1);

      final SyncRunReport second = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(second);
      expect(second.videosExported, 0,
          reason: 'null remote size must not force a re-upload every run');
      expect(second.errors, isEmpty);
    });

    // finding 9：清单条目刷新绝不把既有 coverAsset 抹成 null（本地封面文件丢失 ≠
    // 远端没有封面）。
    test('finding9 keeps prior coverAsset when the local cover file disappears',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      await _seedLocalVideo(db, tmp,
          uid: 'video/Cov', title: 'Cov', coverName: 'cov.jpg');

      // Round 1: cover uploaded, manifest entry carries coverAsset.
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(SyncRunReport());
      final RemoteVideoManifestEntry e1 =
          (await CloudRemoteVideoClient(backend: store).listRemoteVideos())
              .single;
      expect(e1.coverAsset, isNotNull);

      // Local cover file vanishes (moved/deleted on this device) before round 2.
      File(p.join(tmp.path, 'cov.jpg')).deleteSync();

      // Round 2: manifest entry must still carry the coverAsset (not nulled).
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(SyncRunReport());
      final RemoteVideoManifestEntry e2 =
          (await CloudRemoteVideoClient(backend: store).listRemoteVideos())
              .single;
      expect(e2.coverAsset, e1.coverAsset,
          reason:
              'missing local cover file must not wipe published coverAsset');
    });

    // finding 3（原 finding10 修正）：远端 videos.json 存在但读不出（返 null）→ 损坏 →
    // 本轮**跳过视频上传 + 清单回写**并 return。若照传：远端 = 空清单 → priorEntry 恒
    // null → 每轮全量重传（视频体积大的死循环）；若回写：空清单抹掉他端条目。下轮下载
    // 成功即自愈。加第二轮断言：损坏态第二轮仍 videosExported==0（不是每轮重传）。
    test(
        'finding3 corrupt videos.json: skip upload + writeback, no re-transfer loop',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final FakeSyncBackend backend = FakeSyncBackend(store);
      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // Manifest asset present but decodes to null (download-failure / corruption).
      await store.ensureNamespace(kSyncVideosNamespace);
      await store.putJsonAsset(
          kSyncVideosNamespace, kSyncVideosManifestName, null);
      await _seedLocalVideo(db, tmp, uid: 'video/Keep', title: 'Keep');

      final SyncRunReport first = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(first);

      expect(first.videosExported, 0,
          reason: 'corrupt manifest → no idempotency judge → skip upload');
      expect(first.errors.any((String e) => e.contains('unreadable')), isTrue,
          reason: 'corruption recorded');
      // No video file asset uploaded (only the corrupt manifest itself present).
      final List<AssetEntry> uploaded =
          (await store.listChildren(kSyncVideosNamespace))
              .where((AssetEntry e) =>
                  !e.isFolder && e.name != kSyncVideosManifestName)
              .toList();
      expect(uploaded, isEmpty, reason: 'no asset uploaded under corruption');
      final AssetEntry manifest = (await store.findAsset(
          kSyncVideosNamespace, kSyncVideosManifestName))!;
      expect(await store.getJsonAsset(manifest.id), isNull,
          reason:
              'corrupt manifest must NOT be overwritten (would wipe peers)');

      // 第二轮：仍损坏 → 仍 0（关键：不是每轮全量重传的死循环）。
      final SyncRunReport second = SyncRunReport();
      await _orchestrator(db, backend, tmp, syncVideoFiles: true)
          .syncVideoAssets(second);
      expect(second.videosExported, 0,
          reason: 'corrupt manifest must not force a full re-upload each run');
    });
  });

  group('CloudRemoteVideoClient', () {
    test('empty backend lists nothing (never uploaded)', () async {
      final FakeAssetStore store = FakeAssetStore();
      final CloudRemoteVideoClient client =
          CloudRemoteVideoClient(backend: store);
      expect(await client.listRemoteVideos(), isEmpty);
    });

    test('download of unknown uid throws SyncBackendError', () async {
      final FakeAssetStore store = FakeAssetStore();
      final CloudRemoteVideoClient client =
          CloudRemoteVideoClient(backend: store);
      await expectLater(
        client.getRemoteVideo('video/none', File('${work.path}/x.mp4')),
        throwsA(isA<SyncBackendError>()),
      );
    });
  });
}
