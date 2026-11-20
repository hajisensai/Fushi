import 'dart:async';

/// 跑 [body]，期间不停排零延时 Timer，返回调用方 isolate 事件循环两次轮转之间的
/// 最长间隔——[body] 有多长一段同步重活压在本 isolate 上，这个间隔就至少有多长；
/// 重活放进后台 isolate 时它只剩跨 isolate 拷贝的零头。
///
/// 用法是「自校准」：先在本 isolate 同步跑一遍同样的重活量出耗时 `D`，再断言
/// 经被测入口跑时的最长卡顿明显小于 `D`（例如 `< D / 2`）。机器快慢两边一起缩放，
/// 不依赖绝对毫秒数。
Future<({T result, Duration maxStall})> measureEventLoopStall<T>(
  Future<T> Function() body,
) async {
  final Stopwatch clock = Stopwatch()..start();
  Duration last = Duration.zero;
  Duration maxStall = Duration.zero;
  bool done = false;

  void tick() {
    final Duration now = clock.elapsed;
    final Duration gap = now - last;
    if (gap > maxStall) maxStall = gap;
    last = now;
    if (!done) Timer.run(tick);
  }

  Timer.run(tick);
  try {
    final T result = await body();
    // 收尾那一段（body 返回前最后的同步段）也要计入。
    final Duration gap = clock.elapsed - last;
    if (gap > maxStall) maxStall = gap;
    return (result: result, maxStall: maxStall);
  } finally {
    done = true;
  }
}

/// 同步跑一遍 [work]，返回耗时（自校准的基准 `D`）。
Duration measureSync(void Function() work) {
  final Stopwatch clock = Stopwatch()..start();
  work();
  return clock.elapsed;
}
