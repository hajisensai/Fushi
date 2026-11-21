import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_owner.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/aggregate_wire_codec.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// 反馈 c2voByEqPq（BUG-4958）→ HBK-AUDIT-028（BUG-5102 / BUG-5149）：聚合同步的整份
// 快照工作（DB 组装、墓碑裁剪、折叠、差集、报文体编解码）一度全在调用方 isolate
// （app 里即 UI isolate），慢设备上一轮跑满 5 秒被判 ANR；BUG-5102 把纯计算拆成一次
// 次 Isolate.run，整份快照仍要在调用方组装、来回拷贝。现在一轮同步（或 host 的一次
// GET / PUT）由一个后台所有者（AggregateSyncOwner）从头做到尾，调用方只收轻量结果。
//
// 钉法：[debugAggregateSnapshotWorkHook] 是静态字段，每个 isolate 各一份。测试在调用方
// 设上它，后台所有者里那份仍是 null——调用方记下的步骤就是「落在调用方的整份快照
// 工作」，必须为空；同时用真实落库 / 真实上行结果确认这些工作确实做了。

Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  final FushiDatabase db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

/// 在调用方 isolate 记下整份快照工作；[body] 跑完后摘掉钩子并返回记录。
Future<List<String>> _callerSnapshotWork(Future<void> Function() body) async {
  final List<String> steps = <String>[];
  debugAggregateSnapshotWorkHook = steps.add;
  try {
    await body();
  } finally {
    debugAggregateSnapshotWorkHook = null;
  }
  return steps;
}

Future<int> _miningCount(FushiDatabase db, String dateKey) async {
  final AggregateSnapshot snap = await AggregateSyncService(
    db,
  ).materializeLocalSnapshot();
  return snap.miningStats
      .where((MiningRecord r) => r.dateKey == dateKey)
      .fold<int>(0, (int a, MiningRecord r) => a + r.count);
}

AggregateSnapshot _mining(Map<String, int> countsByDate) => AggregateSnapshot(
  miningStats: <MiningRecord>[
    for (final MapEntry<String, int> e in countsByDate.entries)
      MiningRecord(sourceType: 'book', dateKey: e.key, count: e.value),
  ],
);

void main() {
  tearDown(() => debugAggregateSnapshotWorkHook = null);

  test('互联 client 一轮：整份快照工作全在后台所有者里，结果照常落库与上行', () async {
    final FushiDatabase db = await _freshDb('agg_owner_ic_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 1,
    );
    final Uint8List hostBody = encodeAggregateWireJson(
      _mining(<String, int>{'2026-10-02': 5}).toJson(),
    );

    final List<Uint8List> pushed = <Uint8List>[];
    final List<String> callerWork = await _callerSnapshotWork(
      () => AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => hostBody,
        pushMerged: (Uint8List body) async => pushed.add(body),
      ),
    );

    expect(
      callerWork,
      isEmpty,
      reason: '组装 / 解码 / 折叠 / 锁内重读合并 / 裁剪 / 编码都不得落在调用方',
    );
    expect(await _miningCount(db, '2026-10-02'), 5, reason: 'host 的值折进本地');
    expect(pushed, hasLength(1), reason: '本机有 host 没有的数据就 PUT');
    final AggregateSnapshot sent = decodeAggregateWireSnapshot(pushed.single)!;
    expect(
      sent.miningStats.map((MiningRecord r) => r.dateKey).toSet(),
      <String>{'2026-10-01', '2026-10-02'},
    );
  });

  test('互联 client：合并后与 host 内容相同就不 PUT，也不写库', () async {
    final FushiDatabase db = await _freshDb('agg_owner_same_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 3,
    );
    final Uint8List same = encodeAggregateWireJson(
      (await AggregateSyncService(db).materializeLocalSnapshot()).toJson(),
    );
    int pushes = 0;
    int lockEntries = 0;
    final List<String> callerWork = await _callerSnapshotWork(
      () =>
          AggregateSyncService(
            db,
            localApplyLock: (Future<void> Function() body) {
              lockEntries++;
              return body();
            },
          ).syncOverClient(
            fetchRemote: () async => same,
            pushMerged: (Uint8List _) async => pushes++,
          ),
    );
    expect(callerWork, isEmpty);
    expect(pushes, 0);
    expect(lockEntries, 0, reason: '没有写回增量就不进写锁');
  });

  test('互联 client：老 host（无端点）只推本地快照，组装 / 裁剪 / 编码也在后台', () async {
    final FushiDatabase db = await _freshDb('agg_owner_old_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-09',
      count: 2,
    );
    final List<Uint8List> pushed = <Uint8List>[];
    final List<String> callerWork = await _callerSnapshotWork(
      () => AggregateSyncService(db).syncOverClient(
        fetchRemote: () async => null,
        pushMerged: (Uint8List body) async => pushed.add(body),
      ),
    );
    expect(callerWork, isEmpty);
    expect(
      decodeAggregateWireSnapshot(pushed.single)!.miningStats.single.count,
      2,
    );
  });

  // 写锁语义不随执行位置变：锁内「重读 → 合并 → 写回」整段在锁持有期间完成。
  test('锁内写回在后台所有者里做，且整段落在写锁持有期间', () async {
    final FushiDatabase db = await _freshDb('agg_owner_lock_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 1,
    );
    final Uint8List hostBody = encodeAggregateWireJson(
      _mining(<String, int>{'2026-10-05': 9}).toJson(),
    );

    final List<int> atLockEntry = <int>[];
    final List<int> atLockExit = <int>[];
    final List<String> callerWork = await _callerSnapshotWork(
      () =>
          AggregateSyncService(
            db,
            localApplyLock: (Future<void> Function() body) async {
              atLockEntry.add(
                (await db.getMiningStatisticsBySource('book')).length,
              );
              await body();
              atLockExit.add(
                (await db.getMiningStatisticsBySource('book')).length,
              );
            },
          ).syncOverClient(
            fetchRemote: () async => hostBody,
            pushMerged: (Uint8List _) async {},
          ),
    );
    expect(callerWork, isEmpty);
    expect(atLockEntry, <int>[1], reason: '进锁时 host 的行还没写');
    expect(atLockExit, <int>[2], reason: '出锁前写回已经完成');
    expect(await _miningCount(db, '2026-10-05'), 9);
  });

  test('云通道一轮：组装 / 折叠 / 写回 / 裁剪 / 编码哈希都在后台所有者里', () async {
    final FakeAssetStore store = FakeAssetStore();
    final FushiDatabase peerDb = await _freshDb('agg_owner_peer_');
    await peerDb.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-03',
      count: 7,
    );
    await AggregateSyncService(peerDb).sync(store: store, deviceId: 'dev-B');

    final FushiDatabase db = await _freshDb('agg_owner_cloud_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 1,
    );
    late bool uploaded;
    final List<String> callerWork = await _callerSnapshotWork(() async {
      uploaded = await AggregateSyncService(
        db,
      ).sync(store: store, deviceId: 'dev-A');
    });

    expect(callerWork, isEmpty);
    expect(uploaded, isTrue);
    expect(await _miningCount(db, '2026-10-03'), 7, reason: '对端的值折进本地');
    // 内容没变的第二轮：哈希判定在所有者里，调用方只拿哈希比对，不重传。
    expect(
      await AggregateSyncService(db).sync(store: store, deviceId: 'dev-A'),
      isFalse,
    );
  });

  group('host 端点（app 里与 UI 同一 isolate）', () {
    LocalLibraryHostService host(
      FushiDatabase db, {
      Future<void> Function(Future<void> Function() body)? syncStateLock,
    }) => LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      runSyncStateExclusive: syncStateLock,
    );

    test('GET：组装 + 编码在后台，交回的报文体解码后就是本机快照', () async {
      final FushiDatabase db = await _freshDb('agg_owner_get_');
      await db.setMiningCount(
        sourceType: 'book',
        dateKey: '2026-10-11',
        count: 6,
      );
      late Uint8List body;
      final List<String> callerWork = await _callerSnapshotWork(() async {
        body = await host(db).getAggregateBody();
      });
      expect(callerWork, isEmpty);
      expect(decodeAggregateWireSnapshot(body)!.miningStats.single.count, 6);
    });

    test('PUT：解码在锁外、重读折叠写回在锁内，都在后台；MAX 不缩小', () async {
      final FushiDatabase db = await _freshDb('agg_owner_put_');
      await db.setMiningCount(
        sourceType: 'book',
        dateKey: '2026-10-01',
        count: 4,
      );
      final Uint8List body = encodeAggregateWireJson(
        _mining(<String, int>{'2026-10-01': 2, '2026-10-07': 3}).toJson(),
      );
      final List<int> atLockEntry = <int>[];
      late bool accepted;
      final List<String> callerWork = await _callerSnapshotWork(() async {
        accepted = await host(
          db,
          syncStateLock: (Future<void> Function() inner) async {
            atLockEntry.add(
              (await db.getMiningStatisticsBySource('book')).length,
            );
            await inner();
          },
        ).applyAggregateBody(body);
      });
      expect(callerWork, isEmpty);
      expect(accepted, isTrue);
      expect(atLockEntry, <int>[1], reason: '写回发生在锁内');
      expect(await _miningCount(db, '2026-10-01'), 4, reason: 'MAX 不缩小');
      expect(await _miningCount(db, '2026-10-07'), 3);
    });

    test('PUT：坏 JSON / 顶层非 object / 空体 → false，什么都不写、不进锁', () async {
      final FushiDatabase db = await _freshDb('agg_owner_bad_');
      int lockEntries = 0;
      final LocalLibraryHostService h = host(
        db,
        syncStateLock: (Future<void> Function() inner) {
          lockEntries++;
          return inner();
        },
      );
      for (final String raw in <String>['{oops', '[1]', '']) {
        expect(
          await h.applyAggregateBody(Uint8List.fromList(raw.codeUnits)),
          isFalse,
          reason: raw,
        );
      }
      expect(lockEntries, 0);
      expect(await db.getMiningStatisticsBySource('book'), isEmpty);
    });
  });

  // 审查 PR #4062：写回挪到后台所有者的连接上之后，调用方库上的 stream 查询（首页
  // `watchDashboardDataChanges`、小组件、伴屏、收藏句监听）一度收不到这些写入的表
  // 更新——drift 服务端只把更新广播到后台连接自己的存储，调用方库另有一个存储。
  test('后台所有者写回的表更新会通知调用方库上的 stream 查询', () async {
    final FushiDatabase db = await _freshDb('agg_owner_notify_');
    final Uint8List hostBody = encodeAggregateWireJson(
      _mining(<String, int>{'2026-10-21': 2}).toJson(),
    );
    // 在同步开始前就订阅：之后第一条 miningStatistics 更新必须到达。
    final Future<void> notified = db
        .tableUpdates(TableUpdateQuery.onTable(db.miningStatistics))
        .first;
    await AggregateSyncService(db).syncOverClient(
      fetchRemote: () async => hostBody,
      pushMerged: (Uint8List body) async {},
    );
    expect(await _miningCount(db, '2026-10-21'), 2, reason: '确实在后台写了库');
    await notified;
  });

  test('对比弹窗：只回每本书的统计条数，解码在后台', () async {
    final Uint8List body = encodeAggregateWireJson(
      const AggregateSnapshot(
        readingStats: <ReadingStatRecord>[
          ReadingStatRecord(
            title: '本A',
            dateKey: '2026-10-01',
            charactersRead: 1,
            readingTimeMs: 1,
            lastStatisticModified: 1,
          ),
          ReadingStatRecord(
            title: '本A',
            dateKey: '2026-10-02',
            charactersRead: 1,
            readingTimeMs: 1,
            lastStatisticModified: 1,
          ),
        ],
      ).toJson(),
    );
    late Map<String, int> counts;
    final List<String> callerWork = await _callerSnapshotWork(() async {
      counts = await AggregateSyncService.readingStatCountsByTitle(body);
    });
    expect(callerWork, isEmpty);
    expect(counts, <String, int>{'本A': 2});
    expect(
      await AggregateSyncService.readingStatCountsByTitle(
        Uint8List.fromList('[1]'.codeUnits),
      ),
      isEmpty,
      reason: '顶层非 object 当空快照',
    );
    await expectLater(
      AggregateSyncService.readingStatCountsByTitle(
        Uint8List.fromList('{oops'.codeUnits),
      ),
      throwsFormatException,
    );
  });

  test('所有者：命令异常原样（类型不变）传回；关闭后 isolate 退出、不再收命令', () async {
    final FushiDatabase db = await _freshDb('agg_owner_life_');
    final AggregateSyncOwner owner = await AggregateSyncOwner.spawn(db);
    expect(
      await owner.run<String?>(
        (AggregateOwnerContext c) => Isolate.current.debugName,
      ),
      kAggregateSyncOwnerDebugName,
    );
    await expectLater(
      owner.run<void>(
        (AggregateOwnerContext c) => throw const FormatException('bad'),
      ),
      throwsFormatException,
    );
    // 所有者自己的库连接能读能写，写入调用方立刻可见（同一个库）。
    await owner.run<void>(
      (AggregateOwnerContext c) =>
          c.db.setMiningCount(sourceType: 'book', dateKey: 'k', count: 8),
    );
    expect((await db.getMiningStatisticsBySource('book')).single.count, 8);
    await owner.close();
    await owner.close(); // 幂等
    expect(
      () => owner.run<int>((AggregateOwnerContext c) => 1),
      throwsStateError,
    );
    // 主库连接不受所有者断开影响。
    expect((await db.getMiningStatisticsBySource('book')).single.count, 8);
  });

  test('planFold 与直接组合 merge / localDelta / 指纹逐项一致', () {
    const AggregateSnapshot local = AggregateSnapshot(
      miningStats: <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-10-01', count: 2),
        // host 没有的一条：合并结果因此 ≠ host 内容，上行判定要 PUT。
        MiningRecord(sourceType: 'book', dateKey: '2026-09-30', count: 1),
      ],
    );
    const AggregateSnapshot remote = AggregateSnapshot(
      miningStats: <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-10-01', count: 4),
        MiningRecord(sourceType: 'video', dateKey: '2026-10-02', count: 1),
      ],
    );
    final AggregateFoldPlan plan = AggregateSyncService.planFold(
      local: local,
      peerJsons: <Object?>[remote.toJson()],
      stats: true,
      favorites: true,
      webHistory: false,
      fingerprintPeer: true,
    );
    expect(
      plan.merged.toJson(),
      AggregateSyncService.mergeSnapshots(local, remote).toJson(),
    );
    expect(plan.applyNeeded, isTrue);
    expect(
      plan.peerFingerprint,
      AggregateSyncService.unorderedSnapshotFingerprint(remote.toJson()),
    );
    final Uint8List? body = AggregateSyncService.liveOutgoingIfChanged(
      plan.merged,
      plan.peerFingerprint!,
    );
    expect(decodeAggregateWireJson(body!), plan.merged.toJson());
    // 合并结果与 host 内容相同（不计顺序）就不 PUT。
    expect(
      AggregateSyncService.liveOutgoingIfChanged(remote, plan.peerFingerprint!),
      isNull,
    );
  });

  test('planLiveFold：坏 JSON 抛 FormatException、非 object 当空快照', () {
    const AggregateSnapshot local = AggregateSnapshot(
      miningStats: <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-10-01', count: 2),
      ],
    );
    expect(
      () => AggregateSyncService.planLiveFold(
        local: local,
        remoteBody: Uint8List.fromList('{oops'.codeUnits),
        stats: true,
        favorites: true,
        webHistory: false,
      ),
      throwsFormatException,
    );
    final AggregateFoldPlan nonObject = AggregateSyncService.planLiveFold(
      local: local,
      remoteBody: Uint8List.fromList('[1]'.codeUnits),
      stats: true,
      favorites: true,
      webHistory: false,
    );
    expect(nonObject.merged.toJson(), local.toJson());
    expect(nonObject.applyNeeded, isFalse);
  });
}
