/// 量一个异步操作在调用 isolate 上的「单段阻塞」：最长一次不让出事件循环的时长。
///
/// 1 ms 周期计时器：两次触发之间的最大间隔 ≈ 期间最长的一段同步执行（UI 卡顿看的是它，
/// 不是总耗时——总耗时里等后台 isolate / IO 的时间不占 UI 线程）。
library;

import 'dart:async';

/// 一次测量结果（毫秒）。
class EventLoopBlock {
  const EventLoopBlock({required this.maxBlockMs, required this.totalMs});

  /// 最长一段同步执行。
  final int maxBlockMs;

  /// 总耗时。
  final int totalMs;

  @override
  String toString() => 'maxBlock=${maxBlockMs}ms total=${totalMs}ms';
}

/// 跑 [run]，返回它的结果与期间调用 isolate 的单段阻塞。
Future<(T, EventLoopBlock)> measureEventLoopBlock<T>(
  Future<T> Function() run,
) async {
  final Stopwatch sw = Stopwatch()..start();
  int last = 0;
  int maxGap = 0;
  final Timer timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final int now = sw.elapsedMicroseconds;
    if (now - last > maxGap) maxGap = now - last;
    last = now;
  });
  final T value;
  try {
    value = await run();
  } finally {
    timer.cancel();
  }
  final int end = sw.elapsedMicroseconds;
  if (end - last > maxGap) maxGap = end - last;
  return (
    value,
    EventLoopBlock(maxBlockMs: maxGap ~/ 1000, totalMs: end ~/ 1000),
  );
}
