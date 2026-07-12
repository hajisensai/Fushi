import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// 一台设备：自有 DB + deviceId，共享同一 FakeAssetStore（模拟同一云命名空间）。
/// [syncCollections] 复刻编排器的云后端合集阶段（per-device 文件读-合-写）。
class _Dev {
  _Dev(this.db, this.backend, this.tmp, this.deviceId);
  final HibikiDatabase db;
  final FakeSyncBackend backend;
  final Directory tmp;
  final String deviceId;

  SyncOrchestrator get _orch => SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        deviceId: deviceId,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
        syncLocalAudio: false,
      );

  Future<SyncRunReport> sync() async {
    final SyncRunReport report = SyncRunReport();
    await _orch.syncCollections(report);
    return report;
  }

  Future<List<String>> orderOf(String name,
      [String type = 'collection']) async {
    final MediaCollectionRow? row =
        await db.getMediaCollectionByNaturalKey(name, type);
    if (row == null) return const <String>[];
    return (await db.getCollectionItems(row.id))
        .map((MediaCollectionItemRow m) => m.entryKey)
        .toList();
  }
}

void main() {
  late Directory work;
  late FakeAssetStore store; // 共享云。
  late _Dev a;
  late _Dev b;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_coll_');
    store = FakeAssetStore();
    a = _Dev(_memDb(), FakeSyncBackend(store),
        Directory('${work.path}/a')..createSync(), 'devA');
    b = _Dev(_memDb(), FakeSyncBackend(store),
        Directory('${work.path}/b')..createSync(), 'devB');
    addTearDown(() async {
      await a.db.close();
      await b.db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });
  });

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  Future<List<AssetEntry>> manifestFiles() async {
    final List<AssetEntry> children =
        await store.listChildren(kSyncCollectionsNamespace);
    return <AssetEntry>[
      for (final AssetEntry e in children)
        if (!e.isFolder && isCollectionsManifestName(e.name)) e,
    ];
  }

  /// A/B 收敛于合集 Fav{x,y,z}。
  Future<void> seedConverged() async {
    final int c = await a.db.createMediaCollection('Fav');
    await a.db.addToCollection(c, 'epub', 'x');
    await a.db.addToCollection(c, 'epub', 'y');
    await a.db.addToCollection(c, 'epub', 'z');
    await tick();
    await a.sync();
    await b.sync();
    await tick();
    await a.sync();
    expect(await b.orderOf('Fav'), <String>['x', 'y', 'z']);
    expect(await a.orderOf('Fav'), <String>['x', 'y', 'z']);
  }

  group('finding5 per-device collections files', () {
    test(
        'each device writes its own collections-<id>.json (never one shared file)',
        () async {
      await seedConverged();
      final List<String> names = (await manifestFiles())
          .map((AssetEntry e) => e.name)
          .toList()
        ..sort();
      expect(names, <String>['collections-devA.json', 'collections-devB.json'],
          reason: 'per-device layout: 各写各的，绝不共写单文件');
    });

    test(
        'concurrent removals on two devices both survive (no whole-file clobber)',
        () async {
      await seedConverged();

      // A 移出 x、B 移出 z（并发）。
      final int cA =
          (await a.db.getMediaCollectionByNaturalKey('Fav', 'collection'))!.id;
      await a.db.removeFromCollection(cA, 'epub', 'x');
      final int cB =
          (await b.db.getMediaCollectionByNaturalKey('Fav', 'collection'))!.id;
      await b.db.removeFromCollection(cB, 'epub', 'z');
      await tick();

      // 各自发布到自己那份文件（互不覆盖）。
      await a.sync();
      await b.sync();
      await tick();
      // 再互推一轮收敛。
      await a.sync();
      await b.sync();

      // 两处移出都生效——单文件模型下后写者会整文件覆盖先写者丢掉一个墓碑。
      expect(await a.orderOf('Fav'), <String>['y'], reason: 'A 端：x、z 两处移出都保留');
      expect(await b.orderOf('Fav'), <String>['y'], reason: 'B 端：x、z 两处移出都保留');
    });

    test('idempotent: converged devices re-sync writes no new bytes', () async {
      await seedConverged();
      await tick();
      // 记录两份文件的当前字节。
      final Map<String, Object?> before = <String, Object?>{
        for (final AssetEntry e in await manifestFiles())
          e.name: await store.getJsonAsset(e.id),
      };
      final SyncRunReport ra = await a.sync();
      final SyncRunReport rb = await b.sync();
      expect(ra.collectionsUpdated, 0);
      expect(rb.collectionsUpdated, 0);
      final Map<String, Object?> after = <String, Object?>{
        for (final AssetEntry e in await manifestFiles())
          e.name: await store.getJsonAsset(e.id),
      };
      expect(after.keys.toSet(), before.keys.toSet(), reason: '不产生新文件');
      // publishedAt 已定，字节稳定（不每轮重盖 now）。
      for (final String k in before.keys) {
        expect(after[k].toString(), before[k].toString(),
            reason: '$k 字节稳定（含 publishedAt 幂等）');
      }
    });
  });

  group('finding4 baseline race + clock rollback', () {
    test(
        'future persisted baseline is clamped to now (rollback does not freeze sync)',
        () async {
      // B 建 Fav{x} 并发布自己那份（collections-devB.json = Fav{x}）。
      final int c = await b.db.createMediaCollection('Fav');
      await b.db.addToCollection(c, 'epub', 'x');
      await tick();
      await b.sync();
      expect(await b.orderOf('Fav'), <String>['x']);

      // 对端在**时钟领先** B 的机器上于「未来」时刻发布了移出 x 的墓碑
      // （publishedAt = now + 1e6）。模拟 B 时钟被拨回：B 的持久化基线是拨回前的
      // 遥远未来值（now + 1e9）。
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int peerPublishedAt = now + 1000 * 1000; // 对端「未来」发布时刻。
      await store.putJsonAsset(
        kSyncCollectionsNamespace,
        'collections-devPeer.json',
        CollectionManifest(collections: <CollectionManifestEntry>[
          CollectionManifestEntry(
            name: 'Fav',
            collectionType: 'collection',
            memberTombstones: <CollectionMemberTombstone>[
              CollectionMemberTombstone(
                  mediaType: 'epub',
                  entryKey: 'x',
                  removedAt: peerPublishedAt,
                  publishedAt: peerPublishedAt),
            ],
          ),
        ]).toJson(),
      );
      await SyncRepository(b.db)
          .setCollectionsSyncBaselineMs(now + 1000 * 1000 * 1000);

      await b.sync();
      // 无钳制：基线(now+1e9) > publishedAt(now+1e6) → 永远旧闻 → x 复活（同步冻结）。
      // 钳制后基线=now < publishedAt(now+1e6) → 新闻 → x 被移出。
      expect(await b.orderOf('Fav'), isEmpty,
          reason: '时钟回拨钳制：未来基线钳到 now，对端未来发布的移出仍生效，不复活 x');
    });
  });
}
