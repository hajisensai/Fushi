import 'dart:async';

/// 阅读器退出 / 生命周期 flush 链里「实时探针」这一步的延迟预算。
///
/// 正常一次 `evaluateJavascript` 往返是个位数毫秒；600ms 给了两个数量级的余量，
/// 足够盖住「WebView 的 JS 单线程正在跑一次重排/分页、探针排在它后面」这类真实
/// 慢路径，同时仍稳稳落在「按下返回后多久开始觉得按钮坏了」的感知阈之下。
/// 预算用满不代表出错，只代表这次退出落的是缓存锚而不是最新一帧的实时锚。
const Duration kReaderExitProbeBudget = Duration(milliseconds: 600);

/// 阅读器退出 / 生命周期落库链的**延迟契约**：实时探针限时，落库不限时。
///
/// 返回 `true` 表示 [probe] 在预算内正常完成（本次落的是实时锚），`false` 表示
/// 探针超时或抛错、已降级到缓存锚。无论哪种情况 [persist] 都会执行。
///
/// 【为什么需要它】
/// 阅读器的返回是一条全程 await 的串行链，真正的 `nav.pop()` 排在最末：
/// `PopScope.onPopInvokedWithResult` →（`_popInProgress` 单飞门）→ `onWillPop()`
/// → `onSourcePagePop()` → `_syncAndFlushPosition()` → `closeMedia()` → `nav.pop()`。
/// 单飞门在整条链跑完之前一直顶着，期间用户每一次返回（侧滑 / 返回键 / ESC /
/// 手柄 B）都被静默丢弃，且**没有任何 UI 反馈**；更要命的是门只在 `onWillPop()`
/// 真正返回时才由 `finally` 复位——链一旦挂死，门就**永久**顶死，用户不重启 app
/// 就退不出这一页。BUG-1273（await 停播放器）至少还能等播放器停下来自愈，挂死不能。
///
/// 链上唯一没有延迟上界的一段是「向 WebView 实时读进度」
/// （`_syncPositionFromWebViewProgress` 里的 `evaluateJavascript`）：一次平台通道
/// 往返 + WebView 单线程 JS 求值，排在引擎当前正在跑的重排之后，耗时由引擎决定、
/// 不由我们决定。本仓已经为这件事记过一次案——进程退出统一 flush
/// （`_flushAllForProcessExit`）明确**不**调用这个探针，注释原话是「退出期 WebView2
/// 正在拆除，对它 `evaluateJavascript` 会挂死整个退出」。返回路径调的是同一个探针，
/// 却一直没有任何上界。这里补上的就是那个上界。
///
/// 【为什么限时不等于丢数据】
/// 这条链上两类步骤性质完全不同，必须分开对待——这也是本函数把它们拆成两个参数的
/// 全部理由：
/// - [probe] 是**精度**步骤：不写任何持久层，只把内存里的位置锚刷新得更准；
/// - [persist] 是**耐久**步骤：Drift 本地写，用户的真实阅读进度落在这里。
///
/// 所以探针超时的唯一后果是「这次落的是 debounce 已算好的缓存锚，而不是最新一帧的
/// 实时锚」——正是 `_flushAllForProcessExit` 一直以来故意采用的降级口径。
/// [persist] 在探针超时**和**探针抛异常时都照常执行，永不跳过：控制流本身就保证了
/// 「退出后进度不丢」，不依赖调用方自觉。探针抛异常那一路尤其重要——旧形态里
/// 探针的异常会沿 `_syncAndFlushPosition` → `onSourcePagePop` 一路逃逸，把它后面的
/// `_flushPosition()` **和** `_flushReadingStats()` 一起跳过，那才是真的丢进度丢统计。
///
/// 超时不取消 [probe]：`Future.timeout` 只是不再等它，底层求值继续跑完并照常写它的
/// 内存字段（调用方自带 `mounted` 守卫）。这里要的是「不再阻塞用户」，不是「中止求值」。
Future<bool> flushWithBoundedProbe({
  required Future<void> Function() probe,
  required Future<void> Function() persist,
  required Duration probeBudget,
  required void Function(Object error, StackTrace stack) onProbeFailure,
}) async {
  bool probed = true;
  try {
    await probe().timeout(probeBudget);
  } catch (error, stack) {
    // 超时（TimeoutException）与探针自身抛错走同一条降级路径：两者对落库的要求
    // 完全一样（照落缓存锚），分两个分支只会多一个特殊情况。错误交给调用方记录，
    // 不在这里吞掉。
    probed = false;
    onProbeFailure(error, stack);
  }
  await persist();
  return probed;
}
