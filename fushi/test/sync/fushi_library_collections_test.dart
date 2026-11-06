import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_backend.dart' show syncChannelScopeOf;
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import 'local_library_host_service_source_corpus.dart';

/// 互联 host 合集能力测试（多端库联合视图 §2.3 任务5）：
/// - 目录响应含合集归属（[RemoteBookInfo.collection] / [RemoteVideoInfo.collection]）；
/// - 合集清单 endpoint GET/POST roundtrip；
/// - 双端各建合集→经真实 server + client backend + orchestrator 互推→收敛
///   （把 collection_sync_engine_test 的收敛场景搬到 endpoint 全链路层）。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  LocalLibraryHostService buildSvc(FushiDatabase db) => LocalLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory.systemTemp,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
  );

  // ── 任务5.1：目录响应含合集归属 ──────────────────────────────────────────────

  group('目录响应含合集归属（任务5.1）', () {
    test('listBooks 附主合集归属（name/type/sortIndex）', () async {
      final FushiDatabase db = memDb();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'BookA',
          title: 'BookA',
          epubPath: '/tmp/BookA.epub',
          extractDir: '/tmp/BookA',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final int cid = await db.createMediaCollection(
        '文学全集',
        collectionType: 'collection',
      );
      // v83：本地书的成员行 entryKey = epub_books.uid；'Other' 本地无书行，是
      // 照抄对端 bookKey 的透传行（合集清单跨端 union，本机替对端转发归属）。
      await db.addToCollection(cid, MediaKind.epub, 'Other'); // sortIndex 0
      await db.addToCollection(
        cid,
        MediaKind.epub,
        (await db.resolveEpubBookUid('BookA'))!,
      );
      // ↑ sortIndex 1

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      final RemoteBookInfo bookA = books.firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'BookA',
      );
      expect(bookA.collection, isNotNull);
      expect(bookA.collection!.collectionName, '文学全集');
      expect(bookA.collection!.collectionType, 'collection');
      expect(bookA.collection!.sortIndex, 1);
    });

    test('BUG-3441 listBooks 出清单前先按系列归组：host 没开过书架时散着的 3、4 卷 '
        '也带上系列合集归属（只走同步状态窄锁，不碰整轮同步锁）', () async {
      final FushiDatabase db = memDb();
      Future<void> volume(String title) => db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: title,
          title: title,
          epubPath: '/tmp/$title.cbz',
          extractDir: '/tmp/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: Value(BookFormat.manga.dbValue),
        ),
      );
      await volume('志乃と恋 [3574f94a]');
      await volume('志乃と恋 ２ [e11812e5]');
      // 用户电脑库的真实形状：合集里只有 1、2 卷（从别处同步来 / 早先归的）。
      final int cid = await db.createMediaCollection(
        '志乃と恋',
        collectionType: 'playlist',
      );
      for (final String t in <String>['志乃と恋 [3574f94a]', '志乃と恋 ２ [e11812e5]']) {
        await db.addToCollection(
          cid,
          MediaKind.epub,
          (await db.resolveEpubBookUid(t))!,
        );
      }
      await volume('志乃と恋 3 [998c5526]');
      await volume('志乃と恋 ４');

      int wideLockCalls = 0;
      int narrowLockCalls = 0;
      final LocalLibraryHostService svc = LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) {
          wideLockCalls++;
          return body();
        },
        runSyncStateExclusive: (Future<void> Function() body) {
          narrowLockCalls++;
          return body();
        },
      );
      final Map<String, RemoteBookInfo> byKey = <String, RemoteBookInfo>{
        for (final RemoteBookInfo b in await svc.listBooks()) b.downloadId: b,
      };

      expect(wideLockCalls, 0);
      expect(narrowLockCalls, 1);
      expect(
        <String, int?>{
          for (final MapEntry<String, RemoteBookInfo> e in byKey.entries)
            e.key: e.value.collection?.sortIndex,
        },
        <String, int?>{
          '志乃と恋 [3574f94a]': 0,
          '志乃と恋 ２ [e11812e5]': 1,
          '志乃と恋 3 [998c5526]': 2,
          '志乃と恋 ４': 3,
        },
      );
      expect(
        byKey.values.map((RemoteBookInfo b) => b.collection?.collectionName),
        everyElement('志乃と恋'),
      );
    });

    test('listBooks 对不属任何合集的书归属为 null（散卡）', () async {
      final FushiDatabase db = memDb();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Bare',
          title: 'Bare',
          epubPath: '/tmp/Bare.epub',
          extractDir: '/tmp/Bare',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      expect(books.single.collection, isNull);
    });

    test('一书属多合集 → 归属跟随最小 collectionId（主归属折叠语义）', () async {
      final FushiDatabase db = memDb();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Multi',
          title: 'Multi',
          epubPath: '/tmp/Multi.epub',
          extractDir: '/tmp/Multi',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final int first = await db.createMediaCollection('先建'); // 较小 id
      final int second = await db.createMediaCollection('后建'); // 较大 id
      expect(first < second, isTrue);
      // v83：成员行 entryKey = uid。
      final String multiUid = (await db.resolveEpubBookUid('Multi'))!;
      await db.addToCollection(second, MediaKind.epub, multiUid);
      await db.addToCollection(first, MediaKind.epub, multiUid);

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      final RemoteBookInfo multi = books.firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'Multi',
      );
      expect(
        multi.collection!.collectionName,
        '先建',
        reason: '主归属 = 最小 collectionId 的合集',
      );
    });

    test('v83 窗口期兜底：成员行还是 bookKey（sync 透传行未收敛）时归属不闪断', () async {
      final FushiDatabase db = memDb();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'WindowBook',
          title: 'WindowBook',
          epubPath: '/tmp/WindowBook.epub',
          extractDir: '/tmp/WindowBook',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final int cid = await db.createMediaCollection(
        '窗口集',
        collectionType: 'collection',
      );
      // 刻意用 bookKey 落成员行：模拟「书刚下载落地、sync 尚未把透传行 diff 收敛
      // 成 uid 行」的窗口期。listBooks 组键按 uid 优先、bookKey 兜底，两键任一命
      // 中都要带上归属（收敛由下一轮 apply 完成，此处不许闪断）。
      await db.addToCollection(cid, MediaKind.epub, 'WindowBook');

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      expect(
        books.single.collection,
        isNotNull,
        reason: '未收敛的 bookKey 成员行也必须带归属（uid 优先 + bookKey 兜底）',
      );
      expect(books.single.collection!.collectionName, '窗口集');
    });

    test('BUG-812: srt-backed 有声书经 srt|uid 成员键折进合集（listBooks 兜底）', () async {
      final FushiDatabase db = memDb();
      // srt-backed 有声书：同 bookKey 既有 EpubBooks 又有 SrtBooks 行。
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'AudioVol1',
          title: 'AudioVol1',
          epubPath: '/tmp/AudioVol1.epub',
          extractDir: '/tmp/AudioVol1',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'srtbook_epub_AudioVol1',
          title: 'AudioVol1',
          srtPath: '/tmp/AudioVol1.srt',
          importedAt: 0,
          bookKey: const Value('AudioVol1'),
        ),
      );
      final int cid = await db.createMediaCollection(
        '有声集',
        collectionType: 'collection',
      );
      // 有声书加入合集时以 srt|uid 存（本地书架当 SRT 卡渲染的成员键），非 epub|bookKey。
      await db.addToCollection(cid, MediaKind.srt, 'srtbook_epub_AudioVol1');

      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      final RemoteBookInfo vol1 = books.firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'AudioVol1',
      );
      expect(
        vol1.collection,
        isNotNull,
        reason: 'srt-backed 有声书应经 srt|uid 兜底带上合集归属（BUG-812）',
      );
      expect(vol1.collection!.collectionName, '有声集');
      expect(vol1.collection!.collectionType, 'collection');
      expect(vol1.collection!.sortIndex, 0);
    });

    test('BUG-812: 无 srt 成员的 srt-backed 书归属仍为 null（散卡不误折）', () async {
      final FushiDatabase db = memDb();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'LoneAudio',
          title: 'LoneAudio',
          epubPath: '/tmp/LoneAudio.epub',
          extractDir: '/tmp/LoneAudio',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'srtbook_epub_LoneAudio',
          title: 'LoneAudio',
          srtPath: '/tmp/LoneAudio.srt',
          importedAt: 0,
          bookKey: const Value('LoneAudio'),
        ),
      );
      // 不加入任何合集。
      final List<RemoteBookInfo> books = await buildSvc(db).listBooks();
      expect(books.single.collection, isNull);
    });

    test('listVideos 附主合集归属', () async {
      final FushiDatabase db = memDb();
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep1',
          title: 'Ep1',
          videoPath: '/tmp/ep1.mp4',
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      final int cid = await db.createMediaCollection(
        '番剧',
        collectionType: 'playlist',
      );
      await db.addToCollection(cid, MediaKind.video, 'video/ep1');

      final List<RemoteVideoInfo> videos = await buildSvc(db).listVideos();
      final RemoteVideoInfo ep1 = videos.firstWhere(
        (RemoteVideoInfo v) => v.id == 'video/ep1',
      );
      expect(ep1.collection, isNotNull);
      expect(ep1.collection!.collectionName, '番剧');
      expect(ep1.collection!.collectionType, 'playlist');
      expect(ep1.collection!.sortIndex, 0);
    });

    test('BUG-814: listVideos 对存在的视频文件不做内嵌字幕 ffmpeg 探测（延迟到播放）', () async {
      final FushiDatabase db = memDb();
      final Directory tmp = Directory.systemTemp.createTempSync(
        'hbk_video_probe',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      // 存在的视频文件（走 f.existsSync() 分支，旧实现会在此 spawn ffmpeg）。
      final File video = File('${tmp.path}/ep.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 0]);
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/probe',
          title: 'Probe',
          videoPath: video.path,
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

      final List<RemoteVideoInfo> videos = await buildSvc(db).listVideos();
      final RemoteVideoInfo v = videos.firstWhere(
        (RemoteVideoInfo x) => x.id == 'video/probe',
      );
      // 列表端点是纯 DB/stat 读：内嵌轨探测延迟到 /streamurl，列表恒空。
      expect(
        v.embeddedSubtitleTracks,
        isEmpty,
        reason: 'BUG-814：列表不再枚举内嵌字幕轨（避免逐视频 ffmpeg 超时）',
      );
      // sizeBytes 仍来自廉价 stat（证明文件确被识别为存在、走了 existsSync 分支）。
      expect(v.sizeBytes, 4);
      // 无外挂 sidecar → hasSubtitle 为 false（不再靠内嵌轨点亮）。
      expect(v.hasSubtitle, isFalse);
    });

    test('BUG-814 守卫: host 库服务不得在列表路径引用 ffmpeg 内嵌探测', () {
      // B4 拆分后 listVideos 在 videos.part.dart；负向断言扫主库 + 全部 part 的
      // 合并语料（只扫主库会真空通过）。
      final String src = readLocalLibraryHostServiceSource();
      expect(
        src.contains('listEmbeddedSubtitleTracks'),
        isFalse,
        reason:
            'listVideos 一旦重新引入内嵌字幕 ffmpeg 探测，大库互联视频列表会再次'
            '超过 client 15s 超时变空（BUG-814 回归）',
      );
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
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    const String token = 'collections-token';
    late String base;

    setUp(() async {
      hostDb = memDb();
      server = FushiSyncServer(
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

    Future<InterconnectSyncBackend> buildBackend(FushiDatabase clientDb) async {
      final SyncRepository repo = SyncRepository(clientDb);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: base, enabled: true),
      ]);
      await repo.setFushiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String url, String tok) async => true,
      );
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      return backend;
    }

    SyncOrchestrator orchestrator(
      FushiDatabase clientDb,
      InterconnectSyncBackend backend,
    ) => SyncOrchestrator(
      db: clientDb,
      backend: backend,
      dictionaryResourceRoot: Directory.systemTemp,
      audioDatabaseRoot: Directory.systemTemp,
      tempDir: Directory.systemTemp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );

    Future<void> tick() =>
        Future<void>.delayed(const Duration(milliseconds: 3));

    Future<List<String>> orderOf(
      FushiDatabase db,
      String name, [
      String type = 'playlist',
    ]) async {
      final MediaCollectionRow? row = await db.getMediaCollectionByNaturalKey(
        name,
        type,
      );
      if (row == null) return const <String>[];
      return (await db.getCollectionItems(
        row.id,
      )).map((MediaCollectionItemRow m) => m.entryKey).toList();
    }

    test('GET 返回 host 合集清单；POST 把新合集并入 host DB', () async {
      final int hc = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hc, MediaKind.video, 'v1');

      final FushiDatabase clientDb = memDb();
      final InterconnectSyncBackend backend = await buildBackend(clientDb);

      // GET：host 清单含 S{v1}。
      final CollectionManifest? remote = await backend
          .getRemoteCollectionManifest();
      expect(remote, isNotNull);
      final CollectionManifestEntry sEntry = remote!.collections.firstWhere(
        (CollectionManifestEntry e) => e.name == 'S',
      );
      expect(
        sEntry.members.map((CollectionManifestMember m) => m.entryKey),
        <String>['v1'],
      );

      // POST：推一份含新合集 T{t1} 的清单 → host DB 并入 T。
      final CollectionManifest pushed = CollectionManifest(
        collections: <CollectionManifestEntry>[
          const CollectionManifestEntry(
            name: 'T',
            collectionType: 'collection',
            members: <CollectionManifestMember>[
              CollectionManifestMember(
                mediaType: 'epub',
                entryKey: 't1',
                sortIndex: 0,
              ),
            ],
          ),
        ],
      );
      await backend.putRemoteCollectionManifest(pushed);
      expect(await orderOf(hostDb, 'T', 'collection'), <String>[
        't1',
      ], reason: 'host POST 端点经 mergeCollectionManifest 并入新合集');
    });

    test('双端各建同名 playlist → 一次互推收敛为成员并集（host+client）', () async {
      final int hc = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hc, MediaKind.video, 'v1');
      await hostDb.addToCollection(hc, MediaKind.video, 'v2');
      await tick();

      final FushiDatabase clientDb = memDb();
      final InterconnectSyncBackend backend = await buildBackend(clientDb);
      final int cc = await clientDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await clientDb.addToCollection(cc, MediaKind.video, 'v9');
      await tick();

      final SyncRunReport report = SyncRunReport();
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(report, backend);

      expect(report.collectionsUpdated, greaterThan(0));
      expect(await orderOf(clientDb, 'S'), <String>['v1', 'v2', 'v9']);
      expect(await orderOf(hostDb, 'S'), <String>[
        'v1',
        'v2',
        'v9',
      ], reason: 'host 端点也并入 client 独有成员，双端并集收敛');
    });

    test('client 移出成员 → host 端不复活（成员墓碑经 endpoint 生效）', () async {
      // 先收敛：host 建 S{v1,v2,v3}，client 同步一轮取到全部。
      final int hc = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hc, MediaKind.video, 'v1');
      await hostDb.addToCollection(hc, MediaKind.video, 'v2');
      await hostDb.addToCollection(hc, MediaKind.video, 'v3');
      await tick();

      final FushiDatabase clientDb = memDb();
      final InterconnectSyncBackend backend = await buildBackend(clientDb);
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(await orderOf(clientDb, 'S'), <String>['v1', 'v2', 'v3']);
      await tick();

      // client 移出 v2 → 再同步：host 端应删除 v2（不靠 host 自删）。
      final int cc = (await clientDb.getMediaCollectionByNaturalKey(
        'S',
        'playlist',
      ))!.id;
      await clientDb.removeFromCollection(cc, MediaKind.video, 'v2');
      await tick();
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(await orderOf(hostDb, 'S'), <String>[
        'v1',
        'v3',
      ], reason: 'client 移出经 POST 清单的成员墓碑在 host 生效');

      // 多轮互推：host 并集绝不把 v2 复活（无墓碑就会复活——墓碑存在意义）。
      await tick();
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(await orderOf(clientDb, 'S'), <String>['v1', 'v3']);
      expect(await orderOf(hostDb, 'S'), <String>['v1', 'v3']);
    });

    test('client 拖序 → host 采 client 序（手动序整合集 LWW 经 endpoint）', () async {
      final int hc = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hc, MediaKind.video, 'v1');
      await hostDb.addToCollection(hc, MediaKind.video, 'v2');
      await hostDb.addToCollection(hc, MediaKind.video, 'v3');
      await tick();

      final FushiDatabase clientDb = memDb();
      final InterconnectSyncBackend backend = await buildBackend(clientDb);
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(SyncRunReport(), backend);
      await tick();

      final int cc = (await clientDb.getMediaCollectionByNaturalKey(
        'S',
        'playlist',
      ))!.id;
      await clientDb
          .reorderCollectionItems(cc, <({String mediaType, String entryKey})>[
            (mediaType: 'video', entryKey: 'v3'),
            (mediaType: 'video', entryKey: 'v1'),
            (mediaType: 'video', entryKey: 'v2'),
          ]);
      await tick();
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(SyncRunReport(), backend);

      expect(await orderOf(hostDb, 'S'), <String>[
        'v3',
        'v1',
        'v2',
      ], reason: 'orderUpdatedAt 新者整表覆盖 sortIndex（host 采 client 序）');
      // 幂等：再推一轮零变更、host 序不变。
      await tick();
      final SyncRunReport again = SyncRunReport();
      await orchestrator(
        clientDb,
        backend,
      ).syncCollectionsLiveForTest(again, backend);
      expect(again.collectionsUpdated, 0);
      expect(await orderOf(hostDb, 'S'), <String>['v3', 'v1', 'v2']);
    });
  });

  // ── 稳态不回写：host 不存 publishedAt，client 不得每轮重盖 now 再整份 POST ──
  group('合集 live 同步稳态零 POST（publishedAt 不再每轮重盖）', () {
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    late _CountingCollectionsHostService hostSvc;
    const String token = 'collections-steady-token';
    late String base;

    setUp(() async {
      hostDb = memDb();
      hostSvc = _CountingCollectionsHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp
            .createTempSync('hbk_coll_steady')
            .path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: hostSvc,
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    Future<void> tick() =>
        Future<void>.delayed(const Duration(milliseconds: 3));

    test('host 与 client 各造合集删除 + 成员墓碑，收敛后下一轮不 POST', () async {
      // host 侧知识：活合集 S{v1,v3}（v2 已移出 → 成员墓碑）+ 已删除合集 HD。
      final int hs = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hs, MediaKind.video, 'v1');
      await hostDb.addToCollection(hs, MediaKind.video, 'v2');
      await hostDb.addToCollection(hs, MediaKind.video, 'v3');
      await hostDb.removeFromCollection(hs, MediaKind.video, 'v2');
      final int hd = await hostDb.createMediaCollection(
        'HD',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hd, MediaKind.video, 'h1');
      await hostDb.deleteMediaCollection(hd);
      await tick();

      // client 侧知识：已删除合集 CD + 活合集 C{c1}（c2 已移出 → 成员墓碑）。
      final FushiDatabase clientDb = memDb();
      final SyncRepository repo = SyncRepository(clientDb);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: base, enabled: true),
      ]);
      await repo.setFushiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String url, String tok) async => true,
      );
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      final int cd = await clientDb.createMediaCollection(
        'CD',
        collectionType: 'playlist',
      );
      await clientDb.addToCollection(cd, MediaKind.video, 'd1');
      await clientDb.deleteMediaCollection(cd);
      final int cc = await clientDb.createMediaCollection(
        'C',
        collectionType: 'playlist',
      );
      await clientDb.addToCollection(cc, MediaKind.video, 'c1');
      await clientDb.addToCollection(cc, MediaKind.video, 'c2');
      await clientDb.removeFromCollection(cc, MediaKind.video, 'c2');
      await tick();

      final SyncOrchestrator orch = SyncOrchestrator(
        db: clientDb,
        backend: backend,
        dictionaryResourceRoot: Directory.systemTemp,
        audioDatabaseRoot: Directory.systemTemp,
        tempDir: Directory.systemTemp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

      // 第一轮：client 独有的删除 / 墓碑要发布 → 回写一次。
      final SyncRunReport first = SyncRunReport();
      await orch.syncCollectionsLiveForTest(first, backend);
      expect(first.errors, isEmpty);
      expect(hostSvc.mergePosts, 1, reason: '首轮有 client 独有知识，应回写一次');
      expect(
        await hostDb.getMediaCollectionByNaturalKey('CD', 'playlist'),
        isNull,
        reason: 'client 的合集删除经 POST 在 host 生效',
      );
      expect(
        await clientDb.getMediaCollectionByNaturalKey('HD', 'playlist'),
        isNull,
      );
      await tick();

      // 第二轮：两端知识已一致。host 用户亲手造的删除 / 墓碑 GET 回 null 发布戳；client
      // 若给远端已有的删除 / 墓碑再盖 now，合并结果永远与 host 清单字节不等 → 每轮整份
      // POST。client 本地 DB 存的「进库时刻」也不得掺进合并结果（v125）。
      final CollectionManifest hostBefore = (await backend
          .getRemoteCollectionManifest())!;
      final CollectionSyncOutcome replay = CollectionSyncEngine.merge(
        local: await loadLocalCollectionManifest(clientDb),
        remote: hostBefore,
        lastSyncedAtMs: await repo.getCollectionsSyncBaselineMs(
          syncChannelScopeOf(backend),
        ),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(
        replay.merged.canonicalJson(),
        hostBefore.canonicalJson(),
        reason: '稳态合并结果与 host 清单逐字节相等（不靠比较时忽略字段）',
      );

      final SyncRunReport second = SyncRunReport();
      await orch.syncCollectionsLiveForTest(second, backend);
      expect(second.errors, isEmpty);
      expect(second.collectionsUpdated, 0);
      expect(hostSvc.mergePosts, 1, reason: '稳态第二轮不得 POST');

      // 第三轮依旧零 POST。
      await tick();
      await orch.syncCollectionsLiveForTest(SyncRunReport(), backend);
      expect(hostSvc.mergePosts, 1);
    });
  });

  // ── BUG-3743 后续：host 持久化墓碑发布戳，离线早移出、晚同步的墓碑不被判旧闻 ──
  group('离线移出晚同步：基线更新的另一端不复活（host 存 publishedAt）', () {
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    const String token = 'collections-published-token';
    late String base;

    setUp(() async {
      hostDb = memDb();
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp
            .createTempSync('hbk_coll_published')
            .path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: buildSvc(hostDb),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    Future<void> tick() =>
        Future<void>.delayed(const Duration(milliseconds: 3));

    /// 一个真实互联 client：自己的 DB + backend + orchestrator，同步一轮走
    /// GET → merge → 落库 → POST 全链路。
    Future<Future<void> Function()> client(FushiDatabase db) async {
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: base, enabled: true),
      ]);
      await repo.setFushiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String url, String tok) async => true,
      );
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      final SyncOrchestrator orch = SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: Directory.systemTemp,
        audioDatabaseRoot: Directory.systemTemp,
        tempDir: Directory.systemTemp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );
      return () async {
        final SyncRunReport report = SyncRunReport();
        await orch.syncCollectionsLiveForTest(report, backend);
        expect(report.errors, isEmpty);
      };
    }

    Future<List<String>?> membersOf(FushiDatabase db, String name) async {
      final MediaCollectionRow? row = await db.getMediaCollectionByNaturalKey(
        name,
        'playlist',
      );
      if (row == null) return null;
      return (await db.getCollectionItems(
        row.id,
      )).map((MediaCollectionItemRow m) => m.entryKey).toList();
    }

    test('A 离线 t1 移出成员、t3 才同步；B 基线 t2 → 墓碑胜、不复活', () async {
      final int hs = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hs, MediaKind.video, 'v1');
      await hostDb.addToCollection(hs, MediaKind.video, 'v2');
      await tick();

      final FushiDatabase aDb = memDb();
      final FushiDatabase bDb = memDb();
      final Future<void> Function() syncA = await client(aDb);
      final Future<void> Function() syncB = await client(bDb);
      await syncA();
      await tick();

      // t1：A 离线移出 v2（还没同步）。
      final int as = (await aDb.getMediaCollectionByNaturalKey(
        'S',
        'playlist',
      ))!.id;
      await aDb.removeFromCollection(as, MediaKind.video, 'v2');
      await tick();

      // t2：B 同步一轮，基线推进到 t1 之后；此刻 host 与 B 都还有 v2。
      await syncB();
      expect(await membersOf(bDb, 'S'), <String>['v1', 'v2']);
      await tick();

      // t3：A 上线同步，墓碑（removedAt=t1）进 host。
      await syncA();
      expect(await membersOf(hostDb, 'S'), <String>['v1']);
      await tick();

      // B 再同步：removedAt=t1 早于 B 的基线 t2，只看它会判旧闻、v2 复活；
      // 发布戳晚于 t2 ⇒ 是新闻 ⇒ 移出生效。
      await syncB();
      expect(await membersOf(bDb, 'S'), <String>[
        'v1',
      ], reason: '墓碑对 B 是新闻，B 本地的 v2 不得胜出');
      expect(await membersOf(hostDb, 'S'), <String>[
        'v1',
      ], reason: 'B 不得把 v2 经 POST 加回 host');

      // 多轮后稳定。
      await tick();
      await syncA();
      await syncB();
      expect(await membersOf(aDb, 'S'), <String>['v1']);
      expect(await membersOf(bDb, 'S'), <String>['v1']);
      expect(await membersOf(hostDb, 'S'), <String>['v1']);

      // 机理：host 持久化了墓碑进库时刻并在 GET 清单里输出（晚于移出时刻 t1）。
      final CollectionMemberTombstone hostTomb =
          (await loadLocalCollectionManifest(hostDb)).collections
              .firstWhere((CollectionManifestEntry e) => e.name == 'S')
              .memberTombstones
              .single;
      expect(
        hostTomb.publishedAt,
        isNotNull,
        reason: 'host 必须持久化墓碑进库时刻并在清单里输出',
      );
      expect(hostTomb.publishedAt!, greaterThan(hostTomb.removedAt));
    });

    test('A 离线 t1 删整个合集、t3 才同步；B 基线 t2 → 删除胜、不复活', () async {
      final int hs = await hostDb.createMediaCollection(
        'D',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(hs, MediaKind.video, 'd1');
      await tick();

      final FushiDatabase aDb = memDb();
      final FushiDatabase bDb = memDb();
      final Future<void> Function() syncA = await client(aDb);
      final Future<void> Function() syncB = await client(bDb);
      await syncA();
      await tick();

      final int ad = (await aDb.getMediaCollectionByNaturalKey(
        'D',
        'playlist',
      ))!.id;
      await aDb.deleteMediaCollection(ad);
      await tick();

      await syncB();
      expect(await membersOf(bDb, 'D'), <String>['d1']);
      await tick();

      await syncA();
      expect(await membersOf(hostDb, 'D'), isNull);
      await tick();

      await syncB();
      expect(
        await membersOf(bDb, 'D'),
        isNull,
        reason: '删除对 B 是新闻，B 本地的合集不得以「重建」胜出',
      );
      expect(
        await membersOf(hostDb, 'D'),
        isNull,
        reason: 'B 不得把合集经 POST 重建回 host',
      );

      final CollectionManifestEntry hostDead =
          (await loadLocalCollectionManifest(hostDb)).collections.firstWhere(
            (CollectionManifestEntry e) => e.name == 'D',
          );
      expect(hostDead.deletedAt, isNotNull);
      expect(
        hostDead.deletedPublishedAt,
        isNotNull,
        reason: 'host 必须持久化合集删除的进库时刻并在清单里输出',
      );
      expect(hostDead.deletedPublishedAt!, greaterThan(hostDead.deletedAt!));
    });
  });
}

/// 记录 host 收到几次合集清单 POST（[mergeCollectionManifest]）。
class _CountingCollectionsHostService extends LocalLibraryHostService {
  _CountingCollectionsHostService({
    required super.db,
    required super.dictionaryResourceRoot,
    required super.packages,
    required super.refreshDictionaryCache,
    required super.runExclusive,
  });

  int mergePosts = 0;

  @override
  Future<CollectionManifest> mergeCollectionManifest(
    CollectionManifest incoming,
  ) {
    mergePosts++;
    return super.mergeCollectionManifest(incoming);
  }
}
