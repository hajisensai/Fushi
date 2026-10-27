import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/sync/aggregate_peer_snapshot_cache.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// 聚合同步的「没变就不传」：
//  - 云通道：对端快照的版本标记（AssetEntry.revision）没变就读本地副本、不下载，
//    但照样把它折进合并——本地数据在没有墓碑的情况下丢了也能从副本补回来；
//  - 互联通道：合并结果与 host 刚给的内容相同（不计顺序）就不 PUT。

Future<Directory> _tempDir(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return dir;
}

Future<FushiDatabase> _freshDb(String prefix) async {
  final FushiDatabase db = FushiDatabase((await _tempDir(prefix)).path);
  addTearDown(db.close);
  return db;
}

/// 在 [FakeAssetStore] 外面加上版本标记（每次写入 +1）与下载计数。
class _RevisionedStore extends FakeAssetStore {
  _RevisionedStore({super.reportRevisions = true});

  final Map<String, int> _versions = <String, int>{};
  final List<String> downloads = <String>[];

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    await super.putJsonAsset(namespaceId, name, json);
    final String id = '$namespaceId/$name';
    _versions[id] = (_versions[id] ?? 0) + 1;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      <AssetEntry>[
        for (final AssetEntry e in await super.listChildren(namespaceId))
          AssetEntry(
            id: e.id,
            name: e.name,
            isFolder: e.isFolder,
            sizeBytes: e.sizeBytes,
            revision: reportRevisions && !e.isFolder
                ? 'v${_versions[e.id] ?? 0}'
                : null,
          ),
      ];

  @override
  Future<Object?> getJsonAsset(String assetId) {
    downloads.add(assetId);
    return super.getJsonAsset(assetId);
  }
}

const String _peerAsset = '$kSyncAggregateNamespace/dev-B.fushiaggregate';

void main() {
  late Directory cacheRoot;
  late AggregatePeerSnapshotCache cache;

  setUp(() async {
    cacheRoot = await _tempDir('agg_cache_');
    cache = DirectoryAggregatePeerSnapshotCache(() async => cacheRoot);
  });

  Future<void> peerPublishes(_RevisionedStore store, int count) async {
    final FushiDatabase peerDb = await _freshDb('agg_peer_');
    await peerDb.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: count,
    );
    await AggregateSyncService(peerDb).sync(store: store, deviceId: 'dev-B');
  }

  test('对端版本标记没变：不重下，但照样把副本折进本地', () async {
    final _RevisionedStore store = _RevisionedStore();
    await peerPublishes(store, 7);
    final FushiDatabase db = await _freshDb('agg_local_');
    final AggregateSyncService svc = AggregateSyncService(
      db,
      peerSnapshotCache: cache,
    );

    await svc.sync(store: store, deviceId: 'dev-A');
    expect(
      store.downloads.where((String id) => id == _peerAsset),
      hasLength(1),
    );
    expect((await db.getMiningStatisticsBySource('book')).single.count, 7);

    // 本地在没有墓碑的情况下丢了数据（如恢复了旧备份）。
    await db.delete(db.miningStatistics).go();

    await svc.sync(store: store, deviceId: 'dev-A');
    expect(
      store.downloads.where((String id) => id == _peerAsset),
      hasLength(1),
      reason: '版本标记没变不该再下载',
    );
    expect(
      (await db.getMiningStatisticsBySource('book')).single.count,
      7,
      reason: '跳过下载也必须把对端内容折回来',
    );
  });

  test('对端改了（版本标记变了）就重新下载并合并新值', () async {
    final _RevisionedStore store = _RevisionedStore();
    await peerPublishes(store, 7);
    final FushiDatabase db = await _freshDb('agg_local_');
    final AggregateSyncService svc = AggregateSyncService(
      db,
      peerSnapshotCache: cache,
    );
    await svc.sync(store: store, deviceId: 'dev-A');

    await peerPublishes(store, 9);
    await svc.sync(store: store, deviceId: 'dev-A');

    expect(
      store.downloads.where((String id) => id == _peerAsset),
      hasLength(2),
    );
    expect((await db.getMiningStatisticsBySource('book')).single.count, 9);
  });

  test('后端给不出版本标记（FTP / SFTP）就每轮都下载', () async {
    final _RevisionedStore store = _RevisionedStore(reportRevisions: false);
    await peerPublishes(store, 3);
    final FushiDatabase db = await _freshDb('agg_local_');
    final AggregateSyncService svc = AggregateSyncService(
      db,
      peerSnapshotCache: cache,
    );

    await svc.sync(store: store, deviceId: 'dev-A');
    await svc.sync(store: store, deviceId: 'dev-A');

    expect(
      store.downloads.where((String id) => id == _peerAsset),
      hasLength(2),
    );
  });

  test('资产 id 不同（换了云账号 / 位置）即使标记相同也不命中', () async {
    const AssetEntry original = AssetEntry(
      id: 'a/1',
      name: 'dev-B.fushiaggregate',
      revision: 'r1',
    );
    const AssetEntry moved = AssetEntry(
      id: 'b/1',
      name: 'dev-B.fushiaggregate',
      revision: 'r1',
    );
    await cache.write('ch', original, <String, Object?>{'x': 1});

    expect(await cache.read('ch', original), <String, Object?>{'x': 1});
    expect(await cache.read('ch', moved), isNull);
    expect(await cache.read('other-channel', original), isNull);
  });

  test('对端文件从远端消失后清掉它的副本', () async {
    const AssetEntry gone = AssetEntry(
      id: 'a/1',
      name: 'dev-B.fushiaggregate',
      revision: 'r1',
    );
    const AssetEntry alive = AssetEntry(
      id: 'a/2',
      name: 'dev-C.fushiaggregate',
      revision: 'r1',
    );
    await cache.write('ch', gone, <String, Object?>{});
    await cache.write('ch', alive, <String, Object?>{});

    await cache.retainOnly('ch', <String>{alive.name});

    expect(await cache.read('ch', gone), isNull);
    expect(await cache.read('ch', alive), isNotNull);
  });

  group('互联通道回传', () {
    Future<int> pushesAfterSync(
      FushiDatabase db,
      Map<String, Object?> hostJson,
    ) async {
      int pushes = 0;
      await AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => hostJson,
        pushMerged: (Object _) async => pushes++,
      );
      return pushes;
    }

    test('host 已有完全相同的内容（行序不同）就不 PUT', () async {
      final FushiDatabase db = await _freshDb('agg_ic_');
      await db.setMiningCount(
        sourceType: 'book',
        dateKey: '2026-10-01',
        count: 1,
      );
      await db.setMiningCount(
        sourceType: 'book',
        dateKey: '2026-10-02',
        count: 2,
      );
      final Map<String, Object?> local = (await AggregateSyncService(
        db,
      ).materializeLocalSnapshot()).toJson();
      final Map<String, Object?> hostReordered = <String, Object?>{
        for (final MapEntry<String, Object?> e in local.entries)
          e.key: e.value is List
              ? (e.value! as List).reversed.toList()
              : e.value,
      };
      expect((hostReordered['miningStats']! as List).length, 2);

      expect(await pushesAfterSync(db, hostReordered), 0);
    });

    test('本机有 host 没有的数据就 PUT', () async {
      final FushiDatabase db = await _freshDb('agg_ic_');
      await db.setMiningCount(
        sourceType: 'book',
        dateKey: '2026-10-01',
        count: 1,
      );

      expect(await pushesAfterSync(db, const AggregateSnapshot().toJson()), 1);
    });

    test('指纹区分内容、不区分顺序', () {
      final String a = AggregateSyncService.unorderedSnapshotFingerprint(
        <String, Object?>{
          'l': <Object?>[1, 2],
          'v': 1,
        },
      );
      final String reordered =
          AggregateSyncService.unorderedSnapshotFingerprint(<String, Object?>{
            'v': 1,
            'l': <Object?>[2, 1],
          });
      final String changed = AggregateSyncService.unorderedSnapshotFingerprint(
        <String, Object?>{
          'l': <Object?>[1, 3],
          'v': 1,
        },
      );
      final String duplicated =
          AggregateSyncService.unorderedSnapshotFingerprint(<String, Object?>{
            'l': <Object?>[1, 1, 2],
            'v': 1,
          });
      expect(reordered, a);
      expect(changed, isNot(a));
      expect(duplicated, isNot(a));
    });
  });

  test('WebDAV PROPFIND 解析出 getetag，缺失或为空时是 null', () {
    final WebDavOps ops = WebDavOps(
      baseUrl: 'https://dav.example',
      username: 'u',
      password: 'p',
    );
    addTearDown(ops.close);
    const String xml =
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response><d:href>/root/a.json</d:href><d:propstat><d:prop>'
        '<d:getetag>"abc-123"</d:getetag></d:prop></d:propstat></d:response>'
        '<d:response><d:href>/root/b.json</d:href><d:propstat><d:prop>'
        '<d:displayname>b.json</d:displayname></d:prop></d:propstat>'
        '<d:propstat><d:prop><d:getetag/></d:prop></d:propstat></d:response>'
        '<d:response><d:href>/root/c.json</d:href><d:propstat><d:prop>'
        '<d:getetag></d:getetag></d:prop></d:propstat></d:response>'
        '</d:multistatus>';

    final List<DavEntry> entries = ops.parsePropfindResponse(
      xml,
      'https://dav.example/root/',
    );

    expect(entries.map((DavEntry e) => e.etag).toList(), <String?>[
      '"abc-123"',
      null,
      null,
    ]);
  });
}
