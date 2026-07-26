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

  // 相邻操作之间必须让墙钟严格跨过一毫秒：合集裁决用 `DateTime.now().millisecondsSinceEpoch`
  // 作 publishedAt/文件 lastWrittenAt，[CollectionSyncEngine] 的死活比较是严格 `aliveT >
  // tombPubDecision`（见 collection_sync_engine.dart resolve()）。Windows 系统时钟粒度约
  // 15.6ms：固定 3ms delay 可能整段落在同一 tick 内，两次 now() 返回同一毫秒 → 相邻
  // sync 的时戳撞成平值 → 严格比较退化为平局，成员在满负载并行下随机复活/消失。这里自旋
  // 到 now() 真正前进，保证时戳严格递增，与平台定时器粒度、CPU 负载无关（Stopwatch 无关，
  // 因裁决用的是 DateTime 毫秒，必须让 DateTime 本身前进）。
  Future<void> tick() async {
    final int start = DateTime.now().millisecondsSinceEpoch;
    while (DateTime.now().millisecondsSinceEpoch <= start) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

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
    await a.db.addToCollection(c, MediaKind.epub, 'x');
    await a.db.addToCollection(c, MediaKind.epub, 'y');
    await a.db.addToCollection(c, MediaKind.epub, 'z');
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
      await a.db.removeFromCollection(cA, MediaKind.epub, 'x');
      final int cB =
          (await b.db.getMediaCollectionByNaturalKey('Fav', 'collection'))!.id;
      await b.db.removeFromCollection(cB, MediaKind.epub, 'z');
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
      await b.db.addToCollection(c, MediaKind.epub, 'x');
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

  group('finding1 no self-resurrect on 2nd sync (file lastWrittenAt fold)', () {
    test('same device 2nd sync, peer file unchanged: removed member stays gone',
        () async {
      await seedConverged(); // A/B 收敛 Fav{x,y,z}，两份文件都在。

      // A 移出 x 并发布（tomb x），B **不同步**（devB 仍列 x 活）。
      final int cA =
          (await a.db.getMediaCollectionByNaturalKey('Fav', 'collection'))!.id;
      await a.db.removeFromCollection(cA, MediaKind.epub, 'x');
      await tick();
      await a.sync();
      expect(await a.orderOf('Fav'), <String>['y', 'z']);

      // A **再次**同步，devB 仍是陈旧的 Fav{x,y,z}（x 活）。旧实现：本端已发布墓碑
      // publishedAt==上轮基线，> 基线判 false → 判旧闻 → 陈旧 devB 里 x 重加胜 → 复活。
      // 修后：按文件 lastWrittenAt，devB(旧)不晚于墓碑 publishedAt → 墓碑默认胜。
      await tick();
      final SyncRunReport r = await a.sync();
      expect(await a.orderOf('Fav'), <String>['y', 'z'],
          reason: 'finding1：同端二轮同步不复活自己刚移出的成员');
      expect(r.collectionsUpdated, 0, reason: '第二轮无本地变更');
    });

    test(
        'peer republishes member later than tombstone → intentional re-add wins',
        () async {
      await seedConverged();

      // A 移出 x、发布；B 同步（应用移出）。
      final int cA =
          (await a.db.getMediaCollectionByNaturalKey('Fav', 'collection'))!.id;
      await a.db.removeFromCollection(cA, MediaKind.epub, 'x');
      await tick();
      await a.sync();
      await b.sync();
      expect(await b.orderOf('Fav'), <String>['y', 'z']);

      // B 重加 x 并发布——devB 的 lastWrittenAt 现在晚于墓碑 publishedAt（有意重加）。
      await tick();
      final int cB =
          (await b.db.getMediaCollectionByNaturalKey('Fav', 'collection'))!.id;
      await b.db.addToCollection(cB, MediaKind.epub, 'x');
      await tick();
      await b.sync();
      await a.sync();

      expect((await a.orderOf('Fav')).toSet(), <String>{'x', 'y', 'z'},
          reason: 'finding1：对端文件晚于墓碑且含该成员 = 有意重加，成员复归');
      expect(await a.db.getAllCollectionMemberTombstones(), isEmpty,
          reason: '重加清墓碑');
    });
  });

  group('finding2 corrupt manifest resilience (no whole-run abort)', () {
    test('own file corrupt: self-heal republish, does not abort', () async {
      final int c = await a.db.createMediaCollection('Fav');
      await a.db.addToCollection(c, MediaKind.epub, 'x');
      await tick();
      await a.sync();

      // 损坏本端自己那份（解码为 null）。
      await store.putJsonAsset(
          kSyncCollectionsNamespace, 'collections-devA.json', null);

      await tick();
      final SyncRunReport r = await a.sync();
      expect(r.errors.any((String e) => e.contains('self-heal')), isTrue,
          reason: '本端损坏走自愈分支，不 abort');

      // 本端文件被自愈重写为有效清单，仍带 Fav{x}。
      final AssetEntry own = (await store.findAsset(
          kSyncCollectionsNamespace, 'collections-devA.json'))!;
      final Object? json = await store.getJsonAsset(own.id);
      expect(json, isNotNull, reason: '损坏文件被覆盖为有效清单');
      final CollectionManifest m = CollectionManifest.fromJson(json);
      expect(m.collections.any((CollectionManifestEntry e) => e.name == 'Fav'),
          isTrue);
      // A 本地 DB 未受影响。
      expect(await a.orderOf('Fav'), <String>['x']);
    });

    test('peer file corrupt: skip that file + continue (no abort)', () async {
      // B 发布 Fav{y} 到自己那份。
      final int cB = await b.db.createMediaCollection('Fav');
      await b.db.addToCollection(cB, MediaKind.epub, 'y');
      await tick();
      await b.sync();

      // A 有 Fav{x}。损坏 B 那份（A 视角是对端文件）。
      final int cA = await a.db.createMediaCollection('Fav');
      await a.db.addToCollection(cA, MediaKind.epub, 'x');
      await tick();
      await store.putJsonAsset(
          kSyncCollectionsNamespace, 'collections-devB.json', null);

      // A 同步：跳过损坏的 devB，不 abort，照常回写自己那份 Fav{x}。
      final SyncRunReport r = await a.sync();
      expect(r.errors.any((String e) => e.contains('skipped this run')), isTrue,
          reason: '对端损坏文件被跳过（不 abort）');

      final AssetEntry own = (await store.findAsset(
          kSyncCollectionsNamespace, 'collections-devA.json'))!;
      final CollectionManifest m =
          CollectionManifest.fromJson(await store.getJsonAsset(own.id));
      final CollectionManifestEntry fav = m.collections
          .firstWhere((CollectionManifestEntry e) => e.name == 'Fav');
      expect(fav.members.map((CollectionManifestMember mm) => mm.entryKey),
          contains('x'),
          reason: '本端那份照常写出（可读对端 + 本地的并集）');
      // 跳过了对端 y（本轮没读到），A 只有本地 x——不 abort、不误撤知识。
      expect(await a.orderOf('Fav'), <String>['x']);
    });

    test(
        'legacy single-file collections.json is deleted after per-device publish',
        () async {
      // 预置一份旧单文件 collections.json（per-device 布局前遗留），带 Fav{legacy}。
      await store.putJsonAsset(
        kSyncCollectionsNamespace,
        kSyncCollectionsManifestName,
        const CollectionManifest(collections: <CollectionManifestEntry>[
          CollectionManifestEntry(
            name: 'Fav',
            collectionType: 'collection',
            members: <CollectionManifestMember>[
              CollectionManifestMember(
                  mediaType: 'epub', entryKey: 'legacy', sortIndex: 0),
            ],
          ),
        ]).toJson(),
      );

      // A 有本地 Fav{x}，同步：吸收旧单文件知识（legacy 成员并入）后删除旧单文件。
      final int cA = await a.db.createMediaCollection('Fav');
      await a.db.addToCollection(cA, MediaKind.epub, 'x');
      await tick();
      await a.sync();

      // 旧单文件已删除。
      expect(
          await store.findAsset(
              kSyncCollectionsNamespace, kSyncCollectionsManifestName),
          isNull,
          reason: 'finding1：吸收后删除旧单文件，消除永久陈旧源');
      // legacy 成员被吸收（并入 A 的库）。
      expect((await a.orderOf('Fav')).toSet(),
          containsAll(<String>{'x', 'legacy'}),
          reason: '删除前先吸收旧单文件知识');
    });
  });
}
