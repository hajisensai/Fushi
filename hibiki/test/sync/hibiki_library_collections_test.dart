import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 互联 host 合集能力测试（多端库联合视图 §2.3 任务5）：
/// - 目录响应含合集归属（[RemoteBookInfo.collection] / [RemoteVideoInfo.collection]）；
/// - 合集清单 endpoint GET/POST roundtrip；
/// - 双端各建合集→经真实 server + client backend + orchestrator 互推→收敛
///   （把 collection_sync_engine_test 的收敛场景搬到 endpoint 全链路层）。
void main() {
  HibikiDatabase memDb() {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    return db;
  }

  AppModelLibraryHostService buildSvc(HibikiDatabase db) =>
      AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );

  // ── 任务5.1：目录响应含合集归属 ──────────────────────────────────────────────

  group('目录响应含合集归属（任务5.1）', () {
    test('listBooks 附主合集归属（name/type/sortIndex）', () async {
      final HibikiDatabase db = memDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'BookA',
        title: 'BookA',
        epubPath: '/tmp/BookA.epub',
        extractDir: '/tmp/BookA',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final int cid =
          await db.createMediaCollection('文学全集', collectionType: 'collection');
      await db.addToCollection(cid, 'epub', 'Other'); // sortIndex 0
      await db.addToCollection(cid, 'epub', 'BookA'); // sortIndex 1

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      final RemoteBookInfo bookA =
          books.firstWhere((RemoteBookInfo b) => b.bookKey == 'BookA');
      expect(bookA.collection, isNotNull);
      expect(bookA.collection!.collectionName, '文学全集');
      expect(bookA.collection!.collectionType, 'collection');
      expect(bookA.collection!.sortIndex, 1);
    });

    test('listBooks 对不属任何合集的书归属为 null（散卡）', () async {
      final HibikiDatabase db = memDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bare',
        title: 'Bare',
        epubPath: '/tmp/Bare.epub',
        extractDir: '/tmp/Bare',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      expect(books.single.collection, isNull);
    });

    test('一书属多合集 → 归属跟随最小 collectionId（主归属折叠语义）', () async {
      final HibikiDatabase db = memDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Multi',
        title: 'Multi',
        epubPath: '/tmp/Multi.epub',
        extractDir: '/tmp/Multi',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final int first = await db.createMediaCollection('先建'); // 较小 id
      final int second = await db.createMediaCollection('后建'); // 较大 id
      expect(first < second, isTrue);
      await db.addToCollection(second, 'epub', 'Multi');
      await db.addToCollection(first, 'epub', 'Multi');

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      final RemoteBookInfo multi =
          books.firstWhere((RemoteBookInfo b) => b.bookKey == 'Multi');
      expect(multi.collection!.collectionName, '先建',
          reason: '主归属 = 最小 collectionId 的合集');
    });

    test('BUG-812: srt-backed 有声书经 srt|uid 成员键折进合集（listBooks 兜底）', () async {
      final HibikiDatabase db = memDb();
      // srt-backed 有声书：同 bookKey 既有 EpubBooks 又有 SrtBooks 行。
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'AudioVol1',
        title: 'AudioVol1',
        epubPath: '/tmp/AudioVol1.epub',
        extractDir: '/tmp/AudioVol1',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srtbook_epub_AudioVol1',
        title: 'AudioVol1',
        srtPath: '/tmp/AudioVol1.srt',
        importedAt: 0,
        bookKey: const Value('AudioVol1'),
      ));
      final int cid =
          await db.createMediaCollection('有声集', collectionType: 'collection');
      // 有声书加入合集时以 srt|uid 存（本地书架当 SRT 卡渲染的成员键），非 epub|bookKey。
      await db.addToCollection(cid, 'srt', 'srtbook_epub_AudioVol1');

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      final RemoteBookInfo vol1 =
          books.firstWhere((RemoteBookInfo b) => b.bookKey == 'AudioVol1');
      expect(vol1.collection, isNotNull,
          reason: 'srt-backed 有声书应经 srt|uid 兜底带上合集归属（BUG-812）');
      expect(vol1.collection!.collectionName, '有声集');
      expect(vol1.collection!.collectionType, 'collection');
      expect(vol1.collection!.sortIndex, 0);
    });

    test('BUG-812: 无 srt 成员的 srt-backed 书归属仍为 null（散卡不误折）', () async {
      final HibikiDatabase db = memDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'LoneAudio',
        title: 'LoneAudio',
        epubPath: '/tmp/LoneAudio.epub',
        extractDir: '/tmp/LoneAudio',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srtbook_epub_LoneAudio',
        title: 'LoneAudio',
        srtPath: '/tmp/LoneAudio.srt',
        importedAt: 0,
        bookKey: const Value('LoneAudio'),
      ));
      // 不加入任何合集。
      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      expect(books.single.collection, isNull);
    });

    test('listVideos 附主合集归属', () async {
      final HibikiDatabase db = memDb();
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/ep1',
        title: 'Ep1',
        videoPath: '/tmp/ep1.mp4',
        importedAt: Value(DateTime.now()),
      ));
      final int cid =
          await db.createMediaCollection('番剧', collectionType: 'playlist');
      await db.addToCollection(cid, 'video', 'video/ep1');

      final List<RemoteVideoInfo> videos = await buildSvc(db).listVideos();
      final RemoteVideoInfo ep1 =
          videos.firstWhere((RemoteVideoInfo v) => v.id == 'video/ep1');
      expect(ep1.collection, isNotNull);
      expect(ep1.collection!.collectionName, '番剧');
      expect(ep1.collection!.collectionType, 'playlist');
      expect(ep1.collection!.sortIndex, 0);
    });

    test('BUG-814: listVideos 对存在的视频文件不做内嵌字幕 ffmpeg 探测（延迟到播放）', () async {
      final HibikiDatabase db = memDb();
      final Directory tmp =
          Directory.systemTemp.createTempSync('hbk_video_probe');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // 存在的视频文件（走 f.existsSync() 分支，旧实现会在此 spawn ffmpeg）。
      final File video = File('${tmp.path}/ep.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 0]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/probe',
        title: 'Probe',
        videoPath: video.path,
        importedAt: Value(DateTime.now()),
      ));

      final List<RemoteVideoInfo> videos = await buildSvc(db).listVideos();
      final RemoteVideoInfo v =
          videos.firstWhere((RemoteVideoInfo x) => x.id == 'video/probe');
      // 列表端点是纯 DB/stat 读：内嵌轨探测延迟到 /streamurl，列表恒空。
      expect(v.embeddedSubtitleTracks, isEmpty,
          reason: 'BUG-814：列表不再枚举内嵌字幕轨（避免逐视频 ffmpeg 超时）');
      // sizeBytes 仍来自廉价 stat（证明文件确被识别为存在、走了 existsSync 分支）。
      expect(v.sizeBytes, 4);
      // 无外挂 sidecar → hasSubtitle 为 false（不再靠内嵌轨点亮）。
      expect(v.hasSubtitle, isFalse);
    });

    test('BUG-814 守卫: host 库服务不得在列表路径引用 ffmpeg 内嵌探测', () {
      final String src =
          File('lib/src/sync/app_model_library_host_service.dart')
              .readAsStringSync();
      expect(src.contains('listEmbeddedSubtitleTracks'), isFalse,
          reason: 'listVideos 一旦重新引入内嵌字幕 ffmpeg 探测，大库互联视频列表会再次'
              '超过 client 15s 超时变空（BUG-814 回归）');
    });
  });

  // ── DTO round-trip / 向后兼容 ────────────────────────────────────────────────

  group('RemoteCollectionMembership DTO', () {
    test('RemoteBookInfo toJson/fromJson 保留合集归属', () {
      const RemoteBookInfo info = RemoteBookInfo(
        title: 'B',
        hasContent: true,
        bookKey: 'B',
        collection: RemoteCollectionMembership(
          collectionName: 'コレクション',
          collectionType: 'collection',
          sortIndex: 3,
        ),
      );
      final RemoteBookInfo back = RemoteBookInfo.fromJson(info.toJson());
      expect(back.collection, isNotNull);
      expect(back.collection!.collectionName, 'コレクション');
      expect(back.collection!.collectionType, 'collection');
      expect(back.collection!.sortIndex, 3);
    });

    test('无归属的 toJson 不写 collection 键；旧 host 缺字段降级 null', () {
      const RemoteBookInfo info = RemoteBookInfo(title: 'B', hasContent: true);
      expect(info.toJson().containsKey('collection'), isFalse);
      final RemoteBookInfo legacy = RemoteBookInfo.fromJson(<String, Object?>{
        'title': 'Legacy',
        'hasContent': true,
      });
      expect(legacy.collection, isNull);
    });

    test('RemoteVideoInfo copyWith 保留合集归属', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'v',
        title: 'V',
        collection: RemoteCollectionMembership(
          collectionName: 'P',
          collectionType: 'playlist',
          sortIndex: 1,
        ),
      );
      expect(info.copyWith(hasCover: true).collection?.collectionName, 'P');
    });
  });

  // ── 任务5.2/5.3：清单 endpoint GET/POST + 双端收敛（全链路）──────────────────

  group('合集清单 endpoint + 双端收敛（任务5.2/5.3）', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    const String token = 'collections-token';
    late String base;

    setUp(() async {
      hostDb = memDb();
      server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_coll_srv').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: buildSvc(hostDb),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    Future<HibikiClientSyncBackend> buildBackend(
        HibikiDatabase clientDb) async {
      final SyncRepository repo = SyncRepository(clientDb);
      await repo.setHibikiClientUrls(<HibikiClientUrl>[
        HibikiClientUrl(url: base, enabled: true),
      ]);
      await repo.setHibikiClientToken(token);
      final HibikiClientSyncBackend backend = HibikiClientSyncBackend.withProbe(
          (String url, String tok) async => true);
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      return backend;
    }

    SyncOrchestrator orchestrator(
            HibikiDatabase clientDb, HibikiClientSyncBackend backend) =>
        SyncOrchestrator(
          db: clientDb,
          backend: backend,
          dictionaryResourceRoot: Directory.systemTemp,
          audioDatabaseRoot: Directory.systemTemp,
          tempDir: Directory.systemTemp,
          syncStats: false,
          syncAudioBookPosition: false,
          syncContent: false,
          syncAudioBookFiles: false,
          syncDictionary: false,
          syncLocalAudio: false,
        );

    Future<void> tick() =>
        Future<void>.delayed(const Duration(milliseconds: 3));

    Future<List<String>> orderOf(HibikiDatabase db, String name,
        [String type = 'playlist']) async {
      final MediaCollectionRow? row =
          await db.getMediaCollectionByNaturalKey(name, type);
      if (row == null) return const <String>[];
      return (await db.getCollectionItems(row.id))
          .map((MediaCollectionItemRow m) => m.entryKey)
          .toList();
    }

    test('GET 返回 host 合集清单；POST 把新合集并入 host DB', () async {
      final int hc =
          await hostDb.createMediaCollection('S', collectionType: 'playlist');
      await hostDb.addToCollection(hc, 'video', 'v1');

      final HibikiDatabase clientDb = memDb();
      final HibikiClientSyncBackend backend = await buildBackend(clientDb);

      // GET：host 清单含 S{v1}。
      final CollectionManifest? remote =
          await backend.getRemoteCollectionManifest();
      expect(remote, isNotNull);
      final CollectionManifestEntry sEntry = remote!.collections
          .firstWhere((CollectionManifestEntry e) => e.name == 'S');
      expect(sEntry.members.map((CollectionManifestMember m) => m.entryKey),
          <String>['v1']);

      // POST：推一份含新合集 T{t1} 的清单 → host DB 并入 T。
      final CollectionManifest pushed = CollectionManifest(
        collections: <CollectionManifestEntry>[
          const CollectionManifestEntry(
            name: 'T',
            collectionType: 'collection',
            members: <CollectionManifestMember>[
              CollectionManifestMember(
                  mediaType: 'epub', entryKey: 't1', sortIndex: 0),
            ],
          ),
        ],
      );
      await backend.putRemoteCollectionManifest(pushed);
      expect(await orderOf(hostDb, 'T', 'collection'), <String>['t1'],
          reason: 'host POST 端点经 mergeCollectionManifest 并入新合集');
    });

    test('双端各建同名 playlist → 一次互推收敛为成员并集（host+client）', () async {
      final int hc =
          await hostDb.createMediaCollection('S', collectionType: 'playlist');
      await hostDb.addToCollection(hc, 'video', 'v1');
      await hostDb.addToCollection(hc, 'video', 'v2');
      await tick();

      final HibikiDatabase clientDb = memDb();
      final HibikiClientSyncBackend backend = await buildBackend(clientDb);
      final int cc =
          await clientDb.createMediaCollection('S', collectionType: 'playlist');
      await clientDb.addToCollection(cc, 'video', 'v9');
      await tick();

      final SyncRunReport report = SyncRunReport();
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(report, backend);

      expect(report.collectionsUpdated, greaterThan(0));
      expect(await orderOf(clientDb, 'S'), <String>['v1', 'v2', 'v9']);
      expect(await orderOf(hostDb, 'S'), <String>['v1', 'v2', 'v9'],
          reason: 'host 端点也并入 client 独有成员，双端并集收敛');
    });

    test('client 移出成员 → host 端不复活（成员墓碑经 endpoint 生效）', () async {
      // 先收敛：host 建 S{v1,v2,v3}，client 同步一轮取到全部。
      final int hc =
          await hostDb.createMediaCollection('S', collectionType: 'playlist');
      await hostDb.addToCollection(hc, 'video', 'v1');
      await hostDb.addToCollection(hc, 'video', 'v2');
      await hostDb.addToCollection(hc, 'video', 'v3');
      await tick();

      final HibikiDatabase clientDb = memDb();
      final HibikiClientSyncBackend backend = await buildBackend(clientDb);
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(await orderOf(clientDb, 'S'), <String>['v1', 'v2', 'v3']);
      await tick();

      // client 移出 v2 → 再同步：host 端应删除 v2（不靠 host 自删）。
      final int cc =
          (await clientDb.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
      await clientDb.removeFromCollection(cc, 'video', 'v2');
      await tick();
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(await orderOf(hostDb, 'S'), <String>['v1', 'v3'],
          reason: 'client 移出经 POST 清单的成员墓碑在 host 生效');

      // 多轮互推：host 并集绝不把 v2 复活（无墓碑就会复活——墓碑存在意义）。
      await tick();
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(await orderOf(clientDb, 'S'), <String>['v1', 'v3']);
      expect(await orderOf(hostDb, 'S'), <String>['v1', 'v3']);
    });

    test('client 拖序 → host 采 client 序（手动序整合集 LWW 经 endpoint）', () async {
      final int hc =
          await hostDb.createMediaCollection('S', collectionType: 'playlist');
      await hostDb.addToCollection(hc, 'video', 'v1');
      await hostDb.addToCollection(hc, 'video', 'v2');
      await hostDb.addToCollection(hc, 'video', 'v3');
      await tick();

      final HibikiDatabase clientDb = memDb();
      final HibikiClientSyncBackend backend = await buildBackend(clientDb);
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(SyncRunReport(), backend);
      await tick();

      final int cc =
          (await clientDb.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
      await clientDb.reorderCollectionItems(
        cc,
        <({String mediaType, String entryKey})>[
          (mediaType: 'video', entryKey: 'v3'),
          (mediaType: 'video', entryKey: 'v1'),
          (mediaType: 'video', entryKey: 'v2'),
        ],
      );
      await tick();
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(SyncRunReport(), backend);

      expect(await orderOf(hostDb, 'S'), <String>['v3', 'v1', 'v2'],
          reason: 'orderUpdatedAt 新者整表覆盖 sortIndex（host 采 client 序）');
      // 幂等：再推一轮零变更、host 序不变。
      await tick();
      final SyncRunReport again = SyncRunReport();
      await orchestrator(clientDb, backend)
          .syncCollectionsLiveForTest(again, backend);
      expect(again.collectionsUpdated, 0);
      expect(await orderOf(hostDb, 'S'), <String>['v3', 'v1', 'v2']);
    });
  });
}
