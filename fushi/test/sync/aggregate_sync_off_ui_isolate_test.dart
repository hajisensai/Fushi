import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/aggregate_wire_codec.dart';

import 'fake_asset_store.dart';
import 'temp_dir_cleanup.dart';

// 反馈 c2voByEqPq（BUG-4958）：互联聚合同步在 UI isolate 上同步跑整份快照的折叠、
// 写回增量、逐条 jsonEncode + 排序 + 逐码元哈希的指纹，慢设备上一次跑满 5 秒被判
// ANR（3.3.0 release 栈符号化后全在 unorderedSnapshotFingerprint / _stableHash /
// _JsonStringifier）。这里钉住：这些纯计算全部经 [AggregatePureRunner] 交给真正的
// 后台 isolate 执行（闭包可发送 = 没把持有 DB 连接的服务实例捕获进去），且结果与
// 直接组合纯函数完全一致。

Future<FushiDatabase> _freshDb(String prefix) async {
  final Directory dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => cleanupTempDir(dir));
  final FushiDatabase db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

/// 把每段纯计算交给真实 [Isolate.run]，并记下它确实在另一个 isolate 里执行。
class _RecordingIsolateRunner {
  final List<String?> executedOn = <String?>[];

  Future<R> call<R>(R Function() computation) async {
    final (R result, String? where) = await Isolate.run<(R, String?)>(
      () => (computation(), Isolate.current.debugName),
      debugName: 'agg-test-worker',
    );
    executedOn.add(where);
    return result;
  }
}

Future<int> _miningCount(FushiDatabase db, String dateKey) async {
  final AggregateSnapshot snap = await AggregateSyncService(
    db,
  ).materializeLocalSnapshot();
  return snap.miningStats
      .where((MiningRecord r) => r.dateKey == dateKey)
      .fold<int>(0, (int a, MiningRecord r) => a + r.count);
}

void main() {
  test('互联：折叠 / 指纹 / 上行判定都在后台 isolate 执行，结果照常落地与回传', () async {
    final FushiDatabase db = await _freshDb('agg_offui_ic_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 1,
    );
    final FushiDatabase hostDb = await _freshDb('agg_offui_host_');
    await hostDb.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-02',
      count: 5,
    );
    final Map<String, Object?> hostJson = (await AggregateSyncService(
      hostDb,
    ).materializeLocalSnapshot()).toJson();

    final _RecordingIsolateRunner runner = _RecordingIsolateRunner();
    final List<Object> pushed = <Object>[];
    await AggregateSyncService(db, pureRunner: runner.call).syncOverClient(
      fetchRemote: () async => encodeAggregateWireJson(hostJson),
      pushMerged: (Uint8List body) async =>
          pushed.add(decodeAggregateWireJson(body)!),
    );

    expect(
      runner.executedOn,
      <String?>['agg-test-worker', 'agg-test-worker', 'agg-test-worker'],
      reason: '报文体解码 + 折叠（含 host 指纹）、锁内重读后的合并 / 差集、上行判定 + 编码各一次，都不在调用方 isolate',
    );
    expect(await _miningCount(db, '2026-10-02'), 5, reason: 'host 的值折进本地');
    expect(pushed, hasLength(1), reason: '本机有 host 没有的数据就 PUT');
    final AggregateSnapshot sent = AggregateSnapshot.fromJson(pushed.single);
    expect(
      sent.miningStats.map((MiningRecord r) => r.dateKey).toSet(),
      <String>{'2026-10-01', '2026-10-02'},
    );
  });

  test('互联：合并后与 host 内容相同就不 PUT（判定在后台 isolate 里做）', () async {
    final FushiDatabase db = await _freshDb('agg_offui_same_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 3,
    );
    final Map<String, Object?> same = (await AggregateSyncService(
      db,
    ).materializeLocalSnapshot()).toJson();

    final _RecordingIsolateRunner runner = _RecordingIsolateRunner();
    int pushes = 0;
    await AggregateSyncService(db, pureRunner: runner.call).syncOverClient(
      fetchRemote: () async => encodeAggregateWireJson(same),
      pushMerged: (Uint8List _) async => pushes++,
    );

    expect(runner.executedOn, hasLength(2));
    expect(pushes, 0);
  });

  test('云通道：对端折叠与上行编码 / 哈希都在后台 isolate 执行', () async {
    final FakeAssetStore store = FakeAssetStore();
    final FushiDatabase peerDb = await _freshDb('agg_offui_peer_');
    await peerDb.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-03',
      count: 7,
    );
    await AggregateSyncService(peerDb).sync(store: store, deviceId: 'dev-B');

    final FushiDatabase db = await _freshDb('agg_offui_cloud_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 1,
    );
    final _RecordingIsolateRunner runner = _RecordingIsolateRunner();
    final bool uploaded = await AggregateSyncService(
      db,
      pureRunner: runner.call,
    ).sync(store: store, deviceId: 'dev-A');

    expect(runner.executedOn, <String?>[
      'agg-test-worker',
      'agg-test-worker',
      'agg-test-worker',
    ], reason: '对端折叠、写回时的合并 / 差集、上行编码 / 哈希');
    expect(uploaded, isTrue);
    expect(await _miningCount(db, '2026-10-03'), 7, reason: '对端的值折进本地');
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
    final AggregateSnapshot direct = AggregateSyncService.mergeSnapshots(
      local,
      remote,
    );
    expect(plan.merged.toJson(), direct.toJson());
    expect(plan.applyNeeded, isTrue);
    expect(
      plan.peerFingerprint,
      AggregateSyncService.unorderedSnapshotFingerprint(remote.toJson()),
    );
    expect(
      AggregateSyncService.liveOutgoingIfChanged(
        plan.merged,
        plan.peerFingerprint!,
      ),
      isNotNull,
    );
    // 合并结果与 host 内容相同（不计顺序）就不 PUT。
    expect(
      AggregateSyncService.liveOutgoingIfChanged(remote, plan.peerFingerprint!),
      isNull,
    );

    final AggregateFoldPlan noop = AggregateSyncService.planFold(
      local: remote,
      peerJsons: <Object?>[remote.toJson()],
      stats: true,
      favorites: true,
      webHistory: false,
    );
    expect(noop.applyNeeded, isFalse);
    expect(noop.peerFingerprint, isNull);
  });

  // HBK-AUDIT-028：写锁内「重读本地 → 合并 → 差集」以前直接在调用方 isolate 同步算
  // （host 的 PUT 折叠与本机出站同步的锁内写回都走 foldIntoLocal）。钉住：合并 / 差集
  // 经 runner 在后台算，且这一步发生在锁**持有期间**（事务内合并一致性不变）。
  test('锁内的合并 / 差集在后台 isolate 执行，且仍在写锁持有期间', () async {
    final FushiDatabase db = await _freshDb('agg_offui_lock_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 1,
    );
    final Map<String, Object?> hostJson = const AggregateSnapshot(
      miningStats: <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-10-05', count: 9),
      ],
    ).toJson();

    bool lockHeld = false;
    final List<bool> lockHeldPerHop = <bool>[];
    final _RecordingIsolateRunner inner = _RecordingIsolateRunner();
    Future<R> runner<R>(R Function() computation) {
      lockHeldPerHop.add(lockHeld);
      return inner.call<R>(computation);
    }

    await AggregateSyncService(
      db,
      pureRunner: runner,
      localApplyLock: (Future<void> Function() body) async {
        lockHeld = true;
        try {
          await body();
        } finally {
          lockHeld = false;
        }
      },
    ).syncOverClient(
      fetchRemote: () async => encodeAggregateWireJson(hostJson),
      pushMerged: (Uint8List _) async {},
    );

    expect(inner.executedOn, everyElement('agg-test-worker'));
    expect(lockHeldPerHop, <bool>[
      false,
      true,
      false,
    ], reason: '折叠在锁外、锁内合并 / 差集在锁内、上行编码在锁外');
    expect(await _miningCount(db, '2026-10-05'), 9);
  });

  test('host 侧 foldIntoLocal：合并 / 差集经 runner，结果照常落库', () async {
    final FushiDatabase db = await _freshDb('agg_offui_host_fold_');
    await db.setMiningCount(
      sourceType: 'book',
      dateKey: '2026-10-01',
      count: 4,
    );
    final _RecordingIsolateRunner runner = _RecordingIsolateRunner();
    await AggregateSyncService(db, pureRunner: runner.call).foldIntoLocal(
      const AggregateSnapshot(
        miningStats: <MiningRecord>[
          MiningRecord(sourceType: 'book', dateKey: '2026-10-01', count: 2),
          MiningRecord(sourceType: 'book', dateKey: '2026-10-07', count: 3),
        ],
      ),
    );
    expect(runner.executedOn, <String?>['agg-test-worker']);
    expect(await _miningCount(db, '2026-10-01'), 4, reason: 'MAX 不缩小');
    expect(await _miningCount(db, '2026-10-07'), 3);
  });

  test('报文体编解码：上行判定直接给字节；坏 JSON 抛错、非 object 当空快照', () {
    const AggregateSnapshot local = AggregateSnapshot(
      miningStats: <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-10-01', count: 2),
      ],
    );
    const AggregateSnapshot remote = AggregateSnapshot(
      miningStats: <MiningRecord>[
        MiningRecord(sourceType: 'video', dateKey: '2026-10-02', count: 1),
      ],
    );
    final AggregateFoldPlan plan = AggregateSyncService.planLiveFold(
      local: local,
      remoteBody: encodeAggregateWireJson(remote.toJson()),
      stats: true,
      favorites: true,
      webHistory: false,
    );
    expect(
      plan.merged.toJson(),
      AggregateSyncService.mergeSnapshots(local, remote).toJson(),
    );
    final Uint8List? body = AggregateSyncService.liveOutgoingIfChanged(
      plan.merged,
      plan.peerFingerprint!,
    );
    expect(body, isNotNull);
    expect(decodeAggregateWireJson(body!), plan.merged.toJson());

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
    expect(
      decodeAggregateWireSnapshot(Uint8List.fromList('[1]'.codeUnits)),
      isNull,
    );
  });
}
