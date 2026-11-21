// HBK-AUDIT-028：互联聚合同步**整轮**在调用方 isolate 上的停顿（真库、真路径）。
//
// 用法（packages/fushi_engine 下）：
//   dart run test/bench/aggregate_live_sync_isolate_bench.dart [每族行数=40000]
//
// 两个真实的磁盘库（与 app 同一种连接：drift 后台 isolate），每族（阅读统计 /
// 逐时阅读 / 挖掘计数）N 行。三条路径都走生产入口：
//   - client 一轮：AggregateSyncService.syncOverClient（host 快照里 100 行比本地大
//     → 要写回；本地多 10 行 → 要 PUT），网络换成内存里的报文体；
//   - host GET：AggregateSyncService.encodeLocalWireBody（组装 + 裁剪 + 编码）；
//   - host PUT：AggregateSyncService.applyWireBody（解码 + 锁内重读折叠写回）。
// 用 1 ms 定时器量调用方事件循环：最大停顿、单次 >20 ms 的停顿总和（Windows 定时器
// 粒度约 15.6 ms，所以只把 >20 ms 的算作卡顿）、墙钟。4 次取后 3 次（首次是 JIT
// 预热）的中位数。
//
// 修前（PR #4062 头 ee0bc6bc37：每步一次性 Isolate.run、整份快照往返拷贝，组装 /
// 墓碑裁剪在调用方）同一台桌面机、每族 4 万行（报文 ≈ 9.8 MiB）：
//   client 一轮  最大停顿 61 ms，>20 ms 停顿总和 522 ms，墙钟 3731 ms
//   host GET     最大停顿 36 ms，>20 ms 停顿总和  89 ms，墙钟  446 ms
//   host PUT     最大停顿 51 ms，>20 ms 停顿总和 268 ms，墙钟 1687 ms
// 修后（后台所有者 AggregateSyncOwner，本文件现在量的路径），同机同数据：
//   client 一轮  最大停顿 24 ms，>20 ms 停顿总和  88 ms，墙钟 3609 ms
//   host GET     最大停顿 21 ms，>20 ms 停顿总和  21 ms，墙钟  460 ms
//   host PUT     最大停顿 24 ms，>20 ms 停顿总和  45 ms，墙钟 1592 ms
// （20 ms 上下已是这台 Windows 机 1 ms 定时器的噪声底；墙钟基本不变，省下的是调用方
// 的占用。）
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/aggregate_wire_codec.dart';

String _day(int i) {
  final DateTime d = DateTime.utc(1990).add(Duration(days: i));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 每族 [n] 行（键各不相同）；前 [bumpRows] 行的值加 [bump]；再多 [extra] 行。
AggregateSnapshot _snapshot(
  int n, {
  int bump = 0,
  int bumpRows = 0,
  int extra = 0,
}) {
  int b(int i) => i < bumpRows ? bump : 0;
  return AggregateSnapshot(
    readingStats: <ReadingStatRecord>[
      for (int i = 0; i < n + extra; i++)
        ReadingStatRecord(
          title: '本のタイトル第${i ~/ 300}巻',
          dateKey: _day(i % 300 + (i >= n ? 400 : 0)),
          charactersRead: i * 7 + b(i),
          readingTimeMs: i * 1000 + b(i),
          lastStatisticModified: 1700000000000 + i,
        ),
    ],
    readingHourly: <HourlyRecord>[
      for (int i = 0; i < n + extra; i++)
        HourlyRecord(
          dateKey: _day(i ~/ 24),
          hour: i % 24,
          durationMs: i + 1 + b(i),
        ),
    ],
    miningStats: <MiningRecord>[
      for (int i = 0; i < n + extra; i++)
        MiningRecord(
          sourceType: 'book',
          dateKey: _day(i),
          count: i % 50 + 1 + b(i),
        ),
    ],
  );
}

/// 跑 [body]，返回调用方事件循环的 (最大停顿, >20 ms 停顿总和, 墙钟)。
Future<(int, int, int)> _stall(Future<void> Function() body) async {
  final Stopwatch wall = Stopwatch()..start();
  int last = wall.elapsedMilliseconds;
  int maxGap = 0;
  int sum = 0;
  void tick() {
    final int now = wall.elapsedMilliseconds;
    final int gap = now - last;
    if (gap > maxGap) maxGap = gap;
    if (gap > 20) sum += gap;
    last = now;
  }

  final Timer t = Timer.periodic(
    const Duration(milliseconds: 1),
    (_) => tick(),
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));
  final int start = wall.elapsedMilliseconds;
  await body();
  final int end = wall.elapsedMilliseconds;
  await Future<void>.delayed(const Duration(milliseconds: 5));
  tick();
  t.cancel();
  return (maxGap, sum, end - start);
}

Future<void> main(List<String> args) async {
  final int n = args.isEmpty ? 40000 : int.parse(args.first);
  final Directory root = await Directory.systemTemp.createTemp('agg_bench_');
  await Directory('${root.path}/c').create();
  await Directory('${root.path}/h').create();
  final FushiDatabase client = FushiDatabase('${root.path}/c');
  final FushiDatabase host = FushiDatabase('${root.path}/h');
  final Stopwatch sw = Stopwatch()..start();
  await client.transaction(
    () => AggregateSyncService(
      client,
    ).applySnapshotToLocal(_snapshot(n, extra: 10)),
  );
  await host.transaction(
    () => AggregateSyncService(host).applySnapshotToLocal(_snapshot(n)),
  );
  stdout.writeln('rows/family=$n populate=${sw.elapsedMilliseconds}ms');

  Future<void> lock(Future<void> Function() body) => body();
  final Map<String, List<(int, int, int)>> res =
      <String, List<(int, int, int)>>{};
  const int reps = 4;
  for (int r = 0; r < reps; r++) {
    final Uint8List hostBody = encodeAggregateWireJson(
      _snapshot(n, bump: r + 1, bumpRows: 100).toJson(),
    );
    stdout.writeln(
      'body=${(hostBody.length / 1024 / 1024).toStringAsFixed(1)} MiB',
    );
    int pushedBytes = 0;
    res
        .putIfAbsent('client 一轮', () => <(int, int, int)>[])
        .add(
          await _stall(() async {
            await AggregateSyncService(
              client,
              localApplyLock: lock,
            ).syncOverClient(
              fetchRemote: () async => hostBody,
              pushMerged: (Uint8List b) async => pushedBytes = b.length,
            );
          }),
        );
    if (pushedBytes == 0) stdout.writeln('WARN: client round did not push');
    res
        .putIfAbsent('host GET', () => <(int, int, int)>[])
        .add(
          await _stall(() async {
            await AggregateSyncService(host).encodeLocalWireBody(
              stats: true,
              favorites: true,
              webHistory: false,
            );
          }),
        );
    final Uint8List clientBody = encodeAggregateWireJson(
      _snapshot(n, bump: r + 1, bumpRows: 100, extra: 10).toJson(),
    );
    res
        .putIfAbsent('host PUT', () => <(int, int, int)>[])
        .add(
          await _stall(() async {
            final bool ok =
                await AggregateSyncService(
                  host,
                  localApplyLock: lock,
                ).applyWireBody(
                  clientBody,
                  stats: true,
                  favorites: true,
                  webHistory: false,
                );
            if (!ok) throw StateError('host PUT rejected the body');
          }),
        );
  }
  int median(List<int> xs) => (xs.toList()..sort())[xs.length ~/ 2];
  for (final MapEntry<String, List<(int, int, int)>> e in res.entries) {
    final List<(int, int, int)> xs = e.value.sublist(1); // 丢掉 JIT 预热那次
    stdout.writeln(
      '${e.key}: 调用方最大停顿中位=${median(<int>[for (final x in xs) x.$1])}ms '
      '>20ms停顿总和中位=${median(<int>[for (final x in xs) x.$2])}ms '
      '墙钟中位=${median(<int>[for (final x in xs) x.$3])}ms  各次=${e.value}',
    );
  }
  await client.close();
  await host.close();
  await root.delete(recursive: true);
}
