import 'dart:async';

/// 自校准卡顿测度的采样次数：卡顿与基准都取这么多次里的最小值。
///
/// 本机常态是多个 agent 并发跑测试，单次测度会被 OS 抢占、别的进程抢核这类
/// 噪声顶高（实测负载下 sync=234ms、stall=460ms，单独跑则远低于一半）。这类
/// 噪声只会让测到的间隔**变长**，而真压在本 isolate 上的同步重活每一次都至少
/// 那么长，所以取最小值能滤掉噪声又不丢区分力——只要 N 次里有一次没被抢占。
const int kEventLoopStallSamples = 5;

/// 跑 [body]，期间不停排零延时 Timer，返回调用方 isolate 事件循环两次轮转之间的
/// 最长间隔——[body] 有多长一段同步重活压在本 isolate 上，这个间隔就至少有多长；
/// 重活放进后台 isolate 时它只剩跨 isolate 拷贝的零头。
///
/// 单次测度会混进抢占噪声，断言请用 [measureMinEventLoopStall]。
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

/// 把 [body] 依次跑 [samples] 次（参数是第几次，从 0 起），每次用
/// [measureEventLoopStall] 量最长卡顿，返回各次结果与**最小**的那次卡顿。
///
/// 调用方必须保证每一次 [body] 都真走一遍被测重活（不能第二次起命中缓存 /
/// 走「没变就跳过」的快路径），否则后几次的卡顿天然很小，最小值就没有区分力。
/// [samples] 一般取 [kEventLoopStallSamples]，与 [measureMinSync] 一致。
Future<({List<T> results, Duration minStall, List<Duration> stalls})>
measureMinEventLoopStall<T>(
  int samples,
  Future<T> Function(int run) body,
) async {
  assert(samples > 0);
  final List<T> results = <T>[];
  final List<Duration> stalls = <Duration>[];
  for (int run = 0; run < samples; run++) {
    final ({T result, Duration maxStall}) measured =
        await measureEventLoopStall<T>(() => body(run));
    results.add(measured.result);
    stalls.add(measured.maxStall);
  }
  final Duration minStall = stalls.reduce(
    (Duration a, Duration b) => a < b ? a : b,
  );
  return (results: results, minStall: minStall, stalls: stalls);
}

/// 同步跑一遍 [work]，返回耗时。
Duration measureSync(void Function() work) {
  final Stopwatch clock = Stopwatch()..start();
  work();
  return clock.elapsed;
}

/// 同步跑 [work] [samples] 次，返回最短的一次耗时——自校准的基准 `D`。
///
/// 用法是「自校准」：先用本函数量出同样的重活在本 isolate 同步跑的耗时 `D`，
/// 再用 [measureMinEventLoopStall] 量经被测入口跑时的最长卡顿，断言它明显小于
/// `D`（例如 `< D / 2`）。机器快慢两边一起缩放，不依赖绝对毫秒数；两边都取最小值，
/// 抢占噪声两边一起滤掉（`D` 被噪声顶高会放宽阈值、让同步回归漏网）。
Duration measureMinSync(int samples, void Function() work) {
  assert(samples > 0);
  Duration best = measureSync(work);
  for (int run = 1; run < samples; run++) {
    final Duration cost = measureSync(work);
    if (cost < best) best = cost;
  }
  return best;
}
