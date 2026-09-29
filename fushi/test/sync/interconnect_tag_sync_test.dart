import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/game_identity_index.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/tag_sync.dart';

/// 互联标签同步：小说 / 漫画（epub）、字幕书、视频、合集、游戏的标签在两端保持一致
/// （加入 / 移除 / 改名 / 删标签都传播，不复活），游戏按跨端身份对号。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db =
        FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    return db;
  }

  Future<void> seedBook(FushiDatabase db, String bookKey,
          {String format = 'epub'}) =>
      db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: '/tmp/$bookKey.epub',
        extractDir: '/tmp/$bookKey',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: 0,
        format: Value(format),
      ));

  Future<void> seedVideo(FushiDatabase db, String uid) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(uid),
        videoPath: Value('/abs/$uid.mp4'),
      ));

  Future<void> seedSrt(FushiDatabase db, String uid) =>
      db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: uid,
        title: uid,
        srtPath: '/abs/$uid.srt',
        importedAt: 1,
      ));

  Future<void> seedGame(FushiDatabase db, String id,
      {String? name,
      String? exe,
      Map<String, String> sources = const {}}) async {
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: id,
      name: name ?? id,
      exePath: exe ?? 'Z:\\vn\\$id\\$id.exe',
      workdir: 'Z:\\vn\\$id',
      addedAt: 1700000000000,
    ));
    for (final MapEntry<String, String> s in sources.entries) {
      await db.upsertGalgameSource(GalgameSourcesCompanion.insert(
        gameId: id,
        source: s.key,
        externalId: Value(s.value),
        dataJson: '{}',
        fetchedAt: 1,
      ));
    }
  }

  Future<int> tagId(FushiDatabase db, String name) =>
      db.getOrCreateTagByName(name);

  Future<Set<String>> names(Future<List<BookTagRow>> rows) async =>
      (await rows).map((BookTagRow t) => t.name).toSet();

  /// 模拟一轮 client ↔ host 标签同步（与 SyncOrchestrator._syncTagsLive 同形）。
  Future<void> syncPair(FushiDatabase client, FushiDatabase host) async {
    final TagManifest remote = await loadLocalTagManifest(host);
    await applyTagManifest(client, remote);
    final TagManifest local = await loadLocalTagManifest(client);
    if (!tagManifestCovers(remote, local)) {
      await applyTagManifest(host, local);
    }
  }

  // 让墙钟严格前进，避免同一毫秒的加入 / 移除戳相等（相等时移除胜）。
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  group('五类宿主标签双向一致', () {
    test('书（小说）与漫画：client 加的标签到 host，host 移除后回到 client 也消失', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      for (final FushiDatabase db in <FushiDatabase>[host, client]) {
        await seedBook(db, 'novel');
        await seedBook(db, 'manga', format: 'manga');
      }
      await client.addTagToBook('novel', await tagId(client, '在读'));
      await client.addTagToBook('manga', await tagId(client, '连载'));
      await syncPair(client, host);
      expect(await names(host.getTagsForBook('novel')), <String>{'在读'});
      expect(await names(host.getTagsForBook('manga')), <String>{'连载'});

      await tick();
      await host.removeTagFromBook('novel', await tagId(host, '在读'));
      await syncPair(client, host);
      expect(await names(client.getTagsForBook('novel')), isEmpty,
          reason: 'host 的移除墓碑晚于加入戳，传播到 client');
      // 再同步一轮不会被 client 旧状态复活。
      await syncPair(client, host);
      expect(await names(host.getTagsForBook('novel')), isEmpty);
    });

    test('视频与字幕书标签双向传播', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      for (final FushiDatabase db in <FushiDatabase>[host, client]) {
        await seedVideo(db, 'ep1');
        await seedSrt(db, 'srt1');
      }
      await host.addTagToVideoBook('ep1', await tagId(host, '番剧'));
      await client.addTagToSrtBook('srt1', await tagId(client, '有声书'));
      await syncPair(client, host);
      expect(await names(client.getTagsForVideoBook('ep1')), <String>{'番剧'});
      expect(await names(host.getTagsForSrtBook('srt1')), <String>{'有声书'});

      await tick();
      await client.removeTagFromSrtBook('srt1', await tagId(client, '有声书'));
      await syncPair(client, host);
      expect(await names(host.getTagsForSrtBook('srt1')), isEmpty,
          reason: '字幕书移除以前不写墓碑、不跨端；现在走同一 LWW');
    });

    test('合集标签：增删都传播，合集清单的无时钟标签名不复活已移除的标签', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      final int hc = await host.createMediaCollection('系列A');
      final int cc = await client.createMediaCollection('系列A');
      // 零成员合集在清单调和里按「移空自删」处理，给两端各挂同一个成员。
      await host.addToCollection(hc, MediaKind.video, 'ep1');
      await client.addToCollection(cc, MediaKind.video, 'ep1');
      await client.addTagToCollection(cc, await tagId(client, '追番'));
      await syncPair(client, host);
      expect(await names(host.getTagsForCollection(hc)), <String>{'追番'});

      await tick();
      await host.removeTagFromCollection(hc, await tagId(host, '追番'));
      // 合集清单（旧通道，只带名字）仍把 client 的旧标签名并过来：弱并入不复活。
      final CollectionManifest clientCollections =
          await loadLocalCollectionManifest(client);
      await applyCollectionLocalChanges(
          host,
          CollectionLocalChanges(clientCollections.collections
              .where((CollectionManifestEntry e) => e.name == '系列A')
              .toList()));
      expect(await names(host.getTagsForCollection(hc)), isEmpty,
          reason: '有墓碑的名字不被合集清单的 addedAt=1 复活');

      await syncPair(client, host);
      expect(await names(client.getTagsForCollection(cc)), isEmpty);
    });

    test('改名：对端旧名移除、新名出现，不被对端旧名推回', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      for (final FushiDatabase db in <FushiDatabase>[host, client]) {
        await seedBook(db, 'b');
        await seedVideo(db, 'v');
      }
      final int ct = await tagId(client, '旧名');
      await client.addTagToBook('b', ct);
      await client.addTagToVideoBook('v', ct);
      await syncPair(client, host);
      expect(await names(host.getTagsForBook('b')), <String>{'旧名'});

      await tick();
      await host.updateTag(await tagId(host, '旧名'), name: '新名');
      await syncPair(client, host);
      expect(await names(client.getTagsForBook('b')), <String>{'新名'});
      expect(await names(client.getTagsForVideoBook('v')), <String>{'新名'});
      await syncPair(client, host);
      expect(await names(host.getTagsForBook('b')), <String>{'新名'},
          reason: 'client 残留的旧名映射不得把旧名推回 host');
    });

    test('删标签：从所有宿主移除，对端不复活', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      for (final FushiDatabase db in <FushiDatabase>[host, client]) {
        await seedBook(db, 'b');
      }
      await host.addTagToBook('b', await tagId(host, '临时'));
      await syncPair(client, host);
      expect(await names(client.getTagsForBook('b')), <String>{'临时'});

      await tick();
      await client.deleteTag(await tagId(client, '临时'));
      await syncPair(client, host);
      expect(await names(host.getTagsForBook('b')), isEmpty);
    });

    test('收敛后再同步：零改动、无需回写', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      for (final FushiDatabase db in <FushiDatabase>[host, client]) {
        await seedBook(db, 'b');
        await seedVideo(db, 'v');
      }
      await client.addTagToBook('b', await tagId(client, 'x'));
      await host.addTagToVideoBook('v', await tagId(host, 'y'));
      await syncPair(client, host);

      final TagManifest remote = await loadLocalTagManifest(host);
      expect(await applyTagManifest(client, remote), 0,
          reason: '已一致时不写库（否则表观察者会每个防抖窗自激一轮）');
      expect(tagManifestCovers(remote, await loadLocalTagManifest(client)),
          isTrue);
    });

    test('本机没有的宿主不落孤儿映射，到了之后下一轮补上', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      await seedBook(host, 'only-host');
      await host.addTagToBook('only-host', await tagId(host, 't'));
      await syncPair(client, host);
      expect(await client.getAllTagAssignments(), isEmpty);

      await seedBook(client, 'only-host');
      await syncPair(client, host);
      expect(await names(client.getTagsForBook('only-host')), <String>{'t'});
    });
  });

  group('游戏跨设备身份', () {
    test('两台电脑各自入库的同一款游戏（id 不同）按 VNDB id 对号，标签双向一致', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      await seedGame(host, '1700000000000001',
          name: 'WA2', sources: <String, String>{'vndb': 'v7771'});
      await seedGame(client, '1800000000000009',
          name: 'white album 2',
          exe: 'D:\\games\\wa2\\wa2.exe',
          sources: <String, String>{'vndb': 'v7771', 'bgm': '12345'});
      await host.addTagToGame('1700000000000001', await tagId(host, '神作'));
      await syncPair(client, host);
      expect(await names(client.getTagsForGame('1800000000000009')),
          <String>{'神作'});

      await tick();
      await client.removeTagFromGame(
          '1800000000000009', await tagId(client, '神作'));
      await syncPair(client, host);
      expect(await names(host.getTagsForGame('1700000000000001')), isEmpty);
    });

    test('未刮削的游戏退到标题对号；本机同名两款则拒绝对号（不猜）', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      await seedGame(host, 'h1', name: 'Sanoba Witch');
      await host.addTagToGame('h1', await tagId(host, '柚子社'));

      await seedGame(client, 'c1', name: 'sanoba  witch');
      await syncPair(client, host);
      expect(await names(client.getTagsForGame('c1')), <String>{'柚子社'},
          reason: '标题归一化（大小写 / 连续空白）后唯一命中');

      final FushiDatabase ambiguous = memDb();
      await seedGame(ambiguous, 'a1', name: 'Sanoba Witch');
      await seedGame(ambiguous, 'a2', name: 'Sanoba Witch', exe: 'E:\\x.exe');
      await syncPair(ambiguous, host);
      expect(await ambiguous.getAllTagAssignments(), isEmpty,
          reason: '一个键在本机映射到两款游戏就是歧义，宁可不对号');
    });

    test('合集里的游戏成员维持裸 galgames.id 上 wire（成员无别名，换键会并存 / 复活）', () async {
      final FushiDatabase host = memDb();
      await seedGame(host, 'h1', sources: <String, String>{'vndb': 'v11'});
      final int hc = await host.createMediaCollection('夏季');
      await host.addToCollection(hc, MediaKind.game, 'h1');

      final CollectionManifest remote = await loadLocalCollectionManifest(host);
      expect(remote.collections.single.members.single.entryKey, 'h1',
          reason: '游戏成员与升级前 wire 同形：裸 id，不换成 vndb:/exe:/title: 身份');
    });

    test('升级场景：host 存着旧裸 id 成员，同步后不重复；移出后再同步不复活', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      // client 的游戏已刮削（有唯一跨端身份 vndb:v11）；host 上是升级前由 client
      // 推过去的裸 id 成员（host 没有这款游戏，透传保存）。
      await seedGame(client, 'c1', sources: <String, String>{'vndb': 'v11'});
      final int cc = await client.createMediaCollection('夏季');
      await client.addToCollection(cc, MediaKind.game, 'c1');
      final int hc = await host.createMediaCollection('夏季');
      await host.addToCollection(hc, MediaKind.game, 'c1');

      Future<void> round() async {
        final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
          local: await loadLocalCollectionManifest(client),
          remote: await loadLocalCollectionManifest(host),
          lastSyncedAtMs: 0,
        );
        await applyCollectionLocalChanges(client, outcome.changes);
        // host 侧收下合并结果（与 client POST 回写同形）。
        final CollectionSyncOutcome back = CollectionSyncEngine.merge(
          local: await loadLocalCollectionManifest(host),
          remote: outcome.merged,
          lastSyncedAtMs: 0,
        );
        await applyCollectionLocalChanges(host, back.changes);
      }

      Future<List<String>> members(FushiDatabase db, int id) async =>
          (await db.getCollectionItems(id))
              .map((MediaCollectionItemRow m) => m.entryKey)
              .toList();

      await round();
      expect(await members(client, cc), <String>['c1'], reason: '不出现第二个键');
      expect(await members(host, hc), <String>['c1']);

      await tick();
      await client.removeFromCollection(cc, MediaKind.game, 'c1');
      await round();
      await round();
      expect(await members(client, cc), isEmpty, reason: '移出不被 host 旧键并回来');
      expect(await members(host, hc), isEmpty);
    });

    test('无任何唯一身份时退回裸 id，本机裸 id 仍能解析回自己', () async {
      final FushiDatabase db = memDb();
      await seedGame(db, 'g1', name: 'dup', exe: 'X:\\a.exe');
      await seedGame(db, 'g2', name: 'dup', exe: 'X:\\a.exe');
      final GameIdentityIndex index = await GameIdentityIndex.load(db);
      expect(index.wireIdentity('g1').key, 'g1');
      expect(index.resolve(<String>['g1']), 'g1');
    });
  });

  group('游戏对号的负向约束', () {
    test('外部 id 冲突时拒绝对号，不退到标题 / exe', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      await seedGame(host, 'h1',
          name: 'Clannad', sources: <String, String>{'vndb': 'v4'});
      await host.addTagToGame('h1', await tagId(host, '原版'));
      // 同名、同 exe 路径，但 vndb 条目不同（另一款作品 / 复刻）。
      await seedGame(client, 'c1',
          name: 'Clannad',
          exe: r'Z:\vn\h1\h1.exe',
          sources: <String, String>{'vndb': 'v999'});
      await syncPair(client, host);
      expect(await client.getAllTagAssignments(), isEmpty,
          reason: '外部 id 是硬身份，冲突即不是同一款');
      expect(
          (await GameIdentityIndex.load(client)).resolve(
              <String>['vndb:v4', 'exe:z:/vn/h1/h1.exe', 'title:clannad']),
          isNull);
    });

    test('一边有外部 id、一边没有时仍可按标题对号（不算冲突）', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      await seedGame(host, 'h1',
          name: 'Clannad', sources: <String, String>{'vndb': 'v4'});
      await host.addTagToGame('h1', await tagId(host, '原版'));
      await seedGame(client, 'c1', name: 'CLANNAD');
      await syncPair(client, host);
      expect(await names(client.getTagsForGame('c1')), <String>{'原版'});
    });

    test('未改名的默认名（= exe 文件名）不产 title 键、不参与对号', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase client = memDb();
      await seedGame(host, 'h1', name: 'game', exe: r'C:\A\game.exe');
      await host.addTagToGame('h1', await tagId(host, 'A'));
      await seedGame(client, 'c1', name: 'game', exe: r'D:\B\game.exe');
      await syncPair(client, host);
      expect(await client.getAllTagAssignments(), isEmpty,
          reason: '两款不同游戏的启动器都叫 game.exe，不能按标题串号');

      final GalgameRow row = (await host.getGalgame('h1'))!;
      expect(GameIdentityIndex.candidateKeys(row, const <GalgameSourceRow>[]),
          isNot(contains('title:game')));
    });
  });

  group('互联端点全链路', () {
    test('client 加标签 → 经 /api/library/tags 到 host；host 改动回到 client', () async {
      final FushiDatabase hostDb = memDb();
      final FushiDatabase clientDb = memDb();
      for (final FushiDatabase db in <FushiDatabase>[hostDb, clientDb]) {
        await seedBook(db, 'b');
        await seedVideo(db, 'v');
      }
      const String token = 'tags-token';
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_tags_srv').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: LocalLibraryHostService(
          db: hostDb,
          dictionaryResourceRoot: Directory.systemTemp,
          packages: SyncAssetPackageService(db: hostDb),
          refreshDictionaryCache: () async {},
          runExclusive: (Future<void> Function() body) => body(),
        ),
      );
      await server.start();
      addTearDown(server.stop);

      final SyncRepository repo = SyncRepository(clientDb);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
      ]);
      await repo.setFushiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
          (String url, String tok) async => true);
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      final SyncOrchestrator orchestrator = SyncOrchestrator(
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
      );

      await clientDb.addTagToBook('b', await tagId(clientDb, '收藏'));
      await hostDb.addTagToVideoBook('v', await tagId(hostDb, '重温'));
      final SyncRunReport report = SyncRunReport();
      await orchestrator.syncTagsLiveForTest(report, backend);
      expect(report.errors, isEmpty);
      expect(report.tagsUpdated, 1);
      expect(await names(hostDb.getTagsForBook('b')), <String>{'收藏'});
      expect(await names(clientDb.getTagsForVideoBook('v')), <String>{'重温'});
    });
  });
}
