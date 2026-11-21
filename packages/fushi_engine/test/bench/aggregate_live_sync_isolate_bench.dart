// HBK-AUDIT-028：互联聚合同步各段在**调用方 isolate** 上的阻塞时长，修前 vs 修后。
//
// 用法（packages/fushi_engine 下）：
//   dart run test/bench/aggregate_live_sync_isolate_bench.dart [行数=40000]
//
// 「修前」按旧代码路径在调用方同步执行：GET 报文体 UTF-8 + JSON 解码、锁内
// mergeSnapshots + localDelta、PUT 的 jsonEncode + utf8.encode。
// 「修后」走现在的 AggregateSyncService 静态后台入口（真 Isolate.run），用 1 ms
// 定时器量调用方事件循环的最大停顿与停顿总和（含把入参拷进后台 isolate 的开销）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/aggregate_wire_codec.dart';

AggregateSnapshot _snapshot(int n, int salt) {
  String day(int i) =>
      '2026-${(i % 12 + 1).toString().padLeft(2, '0')}-${(i % 28 + 1).toString().padLeft(2, '0')}';
  return AggregateSnapshot(
    readingStats: <ReadingStatRecord>[
      for (int i = 0; i < n; i++)
        ReadingStatRecord(
          title: '本のタイトル第${i ~/ 300}巻',
          dateKey: day(i),
          charactersRead: i * 7 + salt,
          readingTimeMs: i * 1000 + salt,
          lastStatisticModified: 1700000000000 + i + salt,
        ),
    ],
    readingHourly: <HourlyRecord>[
      for (int i = 0; i < n; i++)
        HourlyRecord(dateKey: day(i), hour: i % 24, durationMs: i + salt),
    ],
    miningStats: <MiningRecord>[
      for (int i = 0; i < n; i++)
        MiningRecord(
          sourceType: i.isEven ? 'book' : 'video',
          dateKey: day(i),
          count: i % 50 + salt,
        ),
    ],
  );
}

/// 跑 [body]，期间每 1 ms 打一次点，返回调用方事件循环的 (最大停顿, 停顿总和>2ms)。
Future<(int, int, int)> _stall(Future<void> Function() body) async {
  final Stopwatch wall = Stopwatch()..start();
  int last = wall.elapsedMilliseconds;
  int maxGap = 0;
  int sum = 0;
  final Timer t = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final int now = wall.elapsedMilliseconds;
    final int gap = now - last;
    if (gap > maxGap) maxGap = gap;
    if (gap > 2) sum += gap;
    last = now;
  });
  await Future<void>.delayed(const Duration(milliseconds: 5));
  final int start = wall.elapsedMilliseconds;
  await body();
  final int end = wall.elapsedMilliseconds;
  await Future<void>.delayed(const Duration(milliseconds: 5));
  final int gap = wall.elapsedMilliseconds - last;
  if (gap > maxGap) maxGap = gap;
  t.cancel();
  return (maxGap, sum, end - start);
}

Future<void> main(List<String> args) async {
  final int n = args.isEmpty ? 40000 : int.parse(args.first);
  final AggregateSnapshot local = _snapshot(n, 0);
  final AggregateSnapshot remote = _snapshot(n, 3);
  final Uint8List remoteBody = encodeAggregateWireJson(remote.toJson());
  final AggregateSnapshot merged = AggregateSyncService.mergeSnapshots(
    local,
    remote,
  );
  // 锁内重读到的本地（模拟网络往返期间本地又涨了一点）。
  final AggregateSnapshot localAgain = _snapshot(n, 1);
  stdout.writeln(
    'rows/family=$n  body=${(remoteBody.length / 1024 / 1024).toStringAsFixed(1)} MiB',
  );

  // 预热 JIT。
  for (int i = 0; i < 2; i++) {
    jsonDecode(utf8.decode(remoteBody));
    AggregateSyncService.localDelta(
      AggregateSyncService.mergeSnapshots(localAgain, merged),
      localAgain,
    );
    utf8.encode(jsonEncode(merged.toJson()));
  }

  final List<(String, Future<void> Function(), Future<void> Function())> segs =
      <(String, Future<void> Function(), Future<void> Function())>[
        (
          'GET 解码(+折叠)',
          () async {
            // 修前：调用方解码出 Map，再把 Map 拷进后台折叠。
            final Object? json = jsonDecode(utf8.decode(remoteBody));
            await Isolate.run(
              () => AggregateSyncService.planFold(
                local: local,
                peerJsons: <Object?>[json],
                stats: true,
                favorites: true,
                webHistory: false,
                fingerprintPeer: true,
              ),
            );
          },
          () async {
            await Isolate.run(
              () => AggregateSyncService.planLiveFold(
                local: local,
                remoteBody: remoteBody,
                stats: true,
                favorites: true,
                webHistory: false,
              ),
            );
          },
        ),
        (
          '锁内合并/差集',
          () async {
            AggregateSyncService.localDelta(
              AggregateSyncService.mergeSnapshots(localAgain, merged),
              localAgain,
            );
          },
          () async {
            await Isolate.run(
              () => AggregateSyncService.foldDelta(localAgain, merged),
            );
          },
        ),
        (
          'PUT 编码',
          () async {
            // 修前：后台只回 Map，调用方再 jsonEncode + utf8.encode。
            final Map<String, Object?> json = await Isolate.run(
              () => merged.toJson(),
            );
            utf8.encode(jsonEncode(json));
          },
          () async {
            await Isolate.run(
              () => AggregateSyncService.liveOutgoingIfChanged(merged, 'x'),
            );
          },
        ),
      ];

  for (final (
        String name,
        Future<void> Function() before,
        Future<void> Function() after,
      )
      in segs) {
    // Windows 定时器粒度约 15.6 ms，单次最大停顿噪声大：各跑 [reps] 次取中位数。
    const int reps = 5;
    final List<int> bMax = <int>[];
    final List<int> aMax = <int>[];
    final List<int> bWall = <int>[];
    final List<int> aWall = <int>[];
    for (int i = 0; i < reps; i++) {
      final (int bm, _, int bw) = await _stall(before);
      final (int am, _, int aw) = await _stall(after);
      bMax.add(bm);
      aMax.add(am);
      bWall.add(bw);
      aWall.add(aw);
    }
    int median(List<int> xs) => (xs.toList()..sort())[xs.length ~/ 2];
    stdout.writeln(
      '$name: 修前 调用方最大停顿中位=${median(bMax)}ms 墙钟中位=${median(bWall)}ms | '
      '修后 最大停顿中位=${median(aMax)}ms 墙钟中位=${median(aWall)}ms '
      '(修前各次 $bMax / 修后各次 $aMax)',
    );
  }
}
