import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_index.dart';
import 'package:hibiki/src/sync/sync_index_service.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// `__index__` 服务层（TODO-2656）：一次列举出计划、结束时发布观测。
//
// 这里盯的是两件事——**省下的往返真的省了**（稳态零写入、内容没变不重复下载），
// 以及**保守性没被优化掉**（对端 dirty、本端首轮、周期性全量到期时必须退回全量）。

/// 统计每种远端操作次数的装饰器。增量同步的收益全部体现为「某个计数为 0」，
/// 所以断言必须能看到计数，而不是只看结果对不对。
class _CountingStore implements SyncAssetStore {
  _CountingStore(this._inner);
  final SyncAssetStore _inner;

  int listCalls = 0;
  int getJson = 0;
  int putJson = 0;
  int deletes = 0;

  void reset() {
    listCalls = 0;
    getJson = 0;
    putJson = 0;
    deletes = 0;
  }

  @override
  Future<String> ensureNamespace(String name) => _inner.ensureNamespace(name);

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _inner.ensureFolder(parentId, name);

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) {
    listCalls++;
    return _inner.listChildren(namespaceId);
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _inner.findAsset(namespaceId, name);

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) =>
      _inner.putAsset(namespaceId, name, file, onProgress: onProgress);

  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) =>
      _inner.getAsset(assetId, destination, onProgress: onProgress);

  @override
  Future<Object?> getJsonAsset(String assetId) {
    getJson++;
    return _inner.getJsonAsset(assetId);
  }

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) {
    putJson++;
    return _inner.putJsonAsset(namespaceId, name, json);
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) {
    deletes++;
    return _inner.deleteAsset(id, isFolder: isFolder);
  }
}

Future<HibikiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  return HibikiDatabase(dir.path);
}

SyncIndexService _service(
  SyncAssetStore store,
  HibikiDatabase db,
  String deviceId,
) =>
    SyncIndexService(
      store: store,
      repo: SyncRepository(db),
      deviceId: deviceId,
      channel: SyncRepository.indexChannelCloud,
    );

const Map<String, SyncIndexBookEntry> _books = <String, SyncIndexBookEntry>{
  'Book A': SyncIndexBookEntry(progressAt: 100, progressFraction: 0.25),
};

/// 距上次全量已过去很久 → 触发周期性兜底。
int get _now => 1000 * 1000 * 1000;

void main() {
  test('首轮索引不可用（本端还没有基准），发布后第二轮可用', () async {
    final HibikiDatabase db = await _freshDb('idx_first_');
    addTearDown(db.close);
    final _CountingStore store = _CountingStore(FakeAssetStore());

    final SyncIndexService s1 = _service(store, db, 'devA');
    final SyncIndexPlan p1 = await s1.plan(nowMs: _now);
    expect(p1.usable, isFalse, reason: '从未发布过索引，没有可比的基准');
    expect(p1.forcedFullSweep, isTrue, reason: '从未跑过全量');

    await s1.publish(
      plan: p1,
      books: _books,
      stages: <String, String>{SyncIndexStage.collections: 'fp1'},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    final SyncIndexService s2 = _service(store, db, 'devA');
    final SyncIndexPlan p2 = await s2.plan(nowMs: _now + 1000);
    expect(p2.usable, isTrue);
    expect(p2.remoteUnchanged, isTrue, reason: '只有本端一台设备，没人动过');
    expect(p2.books['Book A']!.progressAt, 100);
    expect(p2.ownStages[SyncIndexStage.collections], 'fp1');
  });

  test('稳态：什么都没变的一轮，只花一次列举，零写入零下载', () async {
    final HibikiDatabase db = await _freshDb('idx_steady_');
    addTearDown(db.close);
    final _CountingStore store = _CountingStore(FakeAssetStore());

    final SyncIndexService s1 = _service(store, db, 'devA');
    final SyncIndexPlan p1 = await s1.plan(nowMs: _now);
    await s1.publish(
      plan: p1,
      books: _books,
      stages: <String, String>{SyncIndexStage.collections: 'fp1'},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    store.reset();
    final SyncIndexService s2 = _service(store, db, 'devA');
    final SyncIndexPlan p2 = await s2.plan(nowMs: _now + 1000);
    expect(p2.usable, isTrue);

    // 本端自己那份 revision 没变 → 用本地缓存，不重新下载。这正是「不必把刚写上去
    // 的东西再读回来」。
    expect(store.getJson, 0, reason: 'revision 未变时不该重新下载清单');
    expect(store.listCalls, 1, reason: '整个计划只花一次列举');

    // 纯跳过的一轮：内容和 revision 都没变 → 一次写入都不做。若这里变成 >0，
    // 每台设备每轮都会在远端留下改动痕迹，对端的「无人动过」判据就永远为假。
    await s2.publish(
      plan: p2,
      books: _books,
      stages: <String, String>{SyncIndexStage.collections: 'fp1'},
      nowMs: _now + 1000,
      wroteRemote: false,
      wasFullSweep: false,
    );
    expect(store.putJson, 0, reason: '没写远端的一轮不该重传索引');
    expect(store.deletes, 0);
  });

  test('真写了远端 → revision +1，对端据此发现变化', () async {
    final HibikiDatabase db = await _freshDb('idx_bump_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();
    final _CountingStore store = _CountingStore(inner);

    final SyncIndexService s1 = _service(store, db, 'devA');
    final SyncIndexPlan p1 = await s1.plan(nowMs: _now);
    await s1.publish(
      plan: p1,
      books: _books,
      stages: const <String, String>{},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    final SyncIndexService s2 = _service(store, db, 'devA');
    final SyncIndexPlan p2 = await s2.plan(nowMs: _now + 1000);
    final int before = p2.ownRevision;
    await s2.publish(
      plan: p2,
      books: const <String, SyncIndexBookEntry>{
        'Book A': SyncIndexBookEntry(progressAt: 999, progressFraction: 0.9),
      },
      stages: const <String, String>{},
      nowMs: _now + 1000,
      wroteRemote: true,
      wasFullSweep: false,
    );

    final SyncIndexService s3 = _service(store, db, 'devA');
    final SyncIndexPlan p3 = await s3.plan(nowMs: _now + 2000);
    expect(p3.ownRevision, before + 1);
    expect(p3.books['Book A']!.progressAt, 999);

    // 同一设备只留一份有效索引，旧 revision 不堆积。
    final List<AssetEntry> children =
        await inner.listChildren(kSyncIndexNamespace);
    final List<AssetEntry> indexFiles = children
        .where((AssetEntry e) => parseSyncIndexAssetName(e.name) != null)
        .toList();
    expect(indexFiles.length, 1);
  });

  test('对端处于 dirty → 索引整体不可用，本轮退回全量', () async {
    final HibikiDatabase db = await _freshDb('idx_dirty_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();

    final SyncIndexService s1 = _service(inner, db, 'devA');
    final SyncIndexPlan p1 = await s1.plan(nowMs: _now);
    await s1.publish(
      plan: p1,
      books: _books,
      stages: const <String, String>{},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    // 另一台设备正在同步（它已上锁，随时可能改远端）。
    final String ns = await inner.ensureNamespace(kSyncIndexNamespace);
    await inner.putJsonAsset(
      ns,
      syncIndexAssetName(deviceId: 'devB', revision: 4, dirty: true),
      const SyncIndexManifest(deviceId: 'devB', revision: 4, publishedAt: 1)
          .toJson(),
    );

    final SyncIndexService s2 = _service(inner, db, 'devA');
    final SyncIndexPlan p2 = await s2.plan(nowMs: _now + 1000);
    expect(p2.usable, isFalse, reason: '有设备正在写远端，索引记录随时可能失效');
    expect(p2.books, isEmpty, reason: '不可用的计划不得给出任何跳过依据');
  });

  test('本端上轮被中断（自己留下 dirty）→ 本轮退回全量并自愈', () async {
    final HibikiDatabase db = await _freshDb('idx_selfheal_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();

    final SyncIndexService s1 = _service(inner, db, 'devA');
    final SyncIndexPlan p1 = await s1.plan(nowMs: _now);
    await s1.publish(
      plan: p1,
      books: _books,
      stages: const <String, String>{},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    // 上锁后进程被杀：远端只剩一份 dirty。
    final SyncIndexService s2 = _service(inner, db, 'devA');
    final SyncIndexPlan p2 = await s2.plan(nowMs: _now + 1000);
    expect(await s2.markDirty(p2), isTrue);

    final SyncIndexService s3 = _service(inner, db, 'devA');
    final SyncIndexPlan p3 = await s3.plan(nowMs: _now + 2000);
    expect(p3.usable, isFalse, reason: '本端上轮的记录停在写入过程中，不可信');

    // 重新完整跑一轮后恢复可用——中断只让人多跑一次全量，不会永久卡死。
    await s3.publish(
      plan: p3,
      books: _books,
      stages: const <String, String>{},
      nowMs: _now + 2000,
      wroteRemote: true,
      wasFullSweep: true,
    );
    final SyncIndexPlan p4 =
        await _service(inner, db, 'devA').plan(nowMs: _now + 3000);
    expect(p4.usable, isTrue);
  });

  test('周期性全量兜底到期 → 忽略索引走全量', () async {
    final HibikiDatabase db = await _freshDb('idx_periodic_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();

    final SyncIndexService s1 = _service(inner, db, 'devA');
    await s1.publish(
      plan: await s1.plan(nowMs: _now),
      books: _books,
      stages: const <String, String>{},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    final SyncIndexPlan soon =
        await _service(inner, db, 'devA').plan(nowMs: _now + 1000);
    expect(soon.usable, isTrue);
    expect(soon.forcedFullSweep, isFalse);

    final SyncIndexPlan later = await _service(inner, db, 'devA')
        .plan(nowMs: _now + kSyncIndexFullSweepIntervalMs + 1);
    expect(later.forcedFullSweep, isTrue);
    expect(later.usable, isFalse, reason: '旧版本设备可能改了远端却不更新索引，靠周期性全量纠正');
  });

  test('对端 revision 变了 → remoteUnchanged 为假，但每本书仍按自己的时间戳判定', () async {
    final HibikiDatabase db = await _freshDb('idx_peer_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();
    final String ns = await inner.ensureNamespace(kSyncIndexNamespace);

    Future<void> putPeer(int revision, int progressAt) async {
      for (final AssetEntry e in await inner.listChildren(ns)) {
        final SyncIndexAssetRef? r = parseSyncIndexAssetName(e.name);
        if (r != null && r.deviceId == 'devB') await inner.deleteAsset(e.id);
      }
      await inner.putJsonAsset(
        ns,
        syncIndexAssetName(deviceId: 'devB', revision: revision, dirty: false),
        SyncIndexManifest(
          deviceId: 'devB',
          revision: revision,
          publishedAt: 1,
          books: <String, SyncIndexBookEntry>{
            'Book A': SyncIndexBookEntry(
                progressAt: progressAt, progressFraction: 0.9),
          },
        ).toJson(),
      );
    }

    await putPeer(1, 100);
    final SyncIndexService s1 = _service(inner, db, 'devA');
    await s1.publish(
      plan: await s1.plan(nowMs: _now),
      books: _books,
      stages: <String, String>{SyncIndexStage.collections: 'fp1'},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    final SyncIndexPlan stable =
        await _service(inner, db, 'devA').plan(nowMs: _now + 1000);
    expect(stable.remoteUnchanged, isTrue);

    // 对端发布了新内容。
    await putPeer(2, 777);
    final SyncIndexPlan moved =
        await _service(inner, db, 'devA').plan(nowMs: _now + 2000);
    expect(moved.usable, isTrue);
    expect(moved.remoteUnchanged, isFalse, reason: '对端动过远端');
    // 折叠后拿到对端更晚的观测值——这本书因此不会被跳过，会走完整路径拉取。
    expect(moved.books['Book A']!.progressAt, 777);
  });

  test('新设备出现 / 旧设备消失都算「远端动过」', () async {
    final HibikiDatabase db = await _freshDb('idx_peerset_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();
    final String ns = await inner.ensureNamespace(kSyncIndexNamespace);

    final SyncIndexService s1 = _service(inner, db, 'devA');
    await s1.publish(
      plan: await s1.plan(nowMs: _now),
      books: _books,
      stages: const <String, String>{},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );
    expect(
      (await _service(inner, db, 'devA').plan(nowMs: _now + 1000))
          .remoteUnchanged,
      isTrue,
    );

    await inner.putJsonAsset(
      ns,
      syncIndexAssetName(deviceId: 'devC', revision: 1, dirty: false),
      const SyncIndexManifest(deviceId: 'devC', revision: 1, publishedAt: 1)
          .toJson(),
    );
    expect(
      (await _service(inner, db, 'devA').plan(nowMs: _now + 2000))
          .remoteUnchanged,
      isFalse,
      reason: '新设备可能带来本端没见过的数据',
    );
  });

  test('deviceId 为空 → 完全不启用索引（无法区分谁写的）', () async {
    final HibikiDatabase db = await _freshDb('idx_nodev_');
    addTearDown(db.close);
    final _CountingStore store = _CountingStore(FakeAssetStore());

    final SyncIndexPlan plan = await _service(store, db, '').plan(nowMs: _now);
    expect(plan.usable, isFalse);
    expect(store.listCalls, 0, reason: '连列举都不该发');
  });

  test('清单损坏 → 判为不可用而不是当作空索引', () async {
    final HibikiDatabase db = await _freshDb('idx_corrupt_');
    addTearDown(db.close);
    final FakeAssetStore inner = FakeAssetStore();
    final String ns = await inner.ensureNamespace(kSyncIndexNamespace);

    final SyncIndexService s1 = _service(inner, db, 'devA');
    await s1.publish(
      plan: await s1.plan(nowMs: _now),
      books: _books,
      stages: const <String, String>{},
      nowMs: _now,
      wroteRemote: true,
      wasFullSweep: true,
    );

    // 对端那份内容与文件名自相矛盾（revision 对不上）。
    await inner.putJsonAsset(
      ns,
      syncIndexAssetName(deviceId: 'devB', revision: 9, dirty: false),
      const SyncIndexManifest(deviceId: 'devB', revision: 1, publishedAt: 1)
          .toJson(),
    );

    final SyncIndexPlan plan =
        await _service(inner, db, 'devA').plan(nowMs: _now + 1000);
    expect(plan.usable, isFalse);
  });
}
