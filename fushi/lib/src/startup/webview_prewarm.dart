import 'dart:async';

/// 是否应在启动后预热 WebView 引擎，把冷启动成本提前到用户翻书架时。
///
/// 移动端与桌面端都预热，低内存模式一律跳过；**何时**预热不在这里判，一律走
/// [runWebViewPrewarmWhenIdle]（所有平台同一条时机门）。纯逻辑，便于单测；真正的
/// HeadlessInAppWebView 调用留在 main.dart（依赖平台无法单测）。
bool shouldPrewarmWebView({
  required bool isMobile,
  required bool isDesktop,
  required bool lowMemory,
}) {
  if (lowMemory) return false;
  return isMobile || isDesktop;
}

/// 预热 WebView 的**唯一时机门**（所有平台共用）：首帧光栅化之后、且主线程进入
/// 空闲（调度器没有动画 / 帧回调在跑）时，才执行 [prewarm]。
///
/// 为什么（反馈 LQhvpnzzkz，BUG 见 docs/bugs）：旧实现只有桌面端在构造
/// HeadlessInAppWebView 前 `await endOfFrame`，移动端在首帧之前就 `run()`。Android
/// 插件在**主线程同步**初始化 chromium（`AwBrowserProcess` →
/// `BrowserStartupControllerImpl`），而 Flutter 3.29+ 起 Android / iOS 的 UI 线程与
/// 平台主线程合一——低端机上这一步把首帧一起堵死，窗口始终没有焦点，8 秒后
/// `Input dispatching timed out (Application does not have a focused window)` ANR。
/// 这与预热的本意「用户在看主页 / 书架时把冷启动成本吃掉」正相反。
///
/// 注意 `endOfFrame` 不够：启动时 `deferFirstFrame()` 生效期间帧照样 build / layout，
/// `endOfFrame` 会在**首帧还没上屏**时就完成。所以这里等的是
/// [firstFrameRasterized]（生产传 `binding.waitUntilFirstFrameRasterized`），再等
/// [whenIdle]（生产传 `SchedulerBinding.scheduleTask(..., Priority.idle)`：有动画在跑时
/// idle 优先级任务不执行，正好避开首屏入场动效。主页背景这类常驻装饰动画不算——
/// 由 `ambientAwareSchedulingStrategy` 扣除，否则 idle 永远等不到、调度器空转把
/// Windows 输入饿死，BUG-4387）。
///
/// [prewarm] 抛错原样外抛，由调用方（main.dart 已有 try/catch + session 收口）处理。
Future<void> runWebViewPrewarmWhenIdle({
  required Future<void> firstFrameRasterized,
  required Future<void> Function() whenIdle,
  required Future<void> Function() prewarm,
}) async {
  await firstFrameRasterized;
  await whenIdle();
  await prewarm();
}

/// 预热 WebView 的**生命周期看门人**：保证那个 headless WebView 一定会被销毁。
///
/// 为什么需要它——预热是纯优化，但它持有的是**进程级**资源：一个 headless
/// WebView 会拉起一个独立的 chromium renderer 子进程。旧实现把 `dispose()`
/// 挂在 `onLoadStop` 这一条**成功路径**上，于是「回调不来」等于「永久泄漏一个
/// renderer 进程」，而 renderer 一旦被系统 OOM kill，`WebViewClient
/// .onRenderProcessGone` 没人接管时 Android 的默认动作就是**杀掉整个 app
/// 进程**（`AwBrowserTerminator` → SIGTRAP）。CI Android appSmoke 连续 4 次
/// 就死在这条路上：`[Fushi] WebView engine pre-warm` 一次都没打印过（说明
/// dispose 从未执行），随后 `Render process crash wasn't handled by all
/// associated webviews, triggering application crash`。
///
/// 修法不是等更久或重试，而是把「什么时候结束」从单一成功回调改成**先到者胜的
/// 多路终点**：载入完成 / 载入失败 / renderer 进程死亡 / [timeout] 兜底。
/// [finish] 幂等，重复触发是 no-op，所以四条路可以同时接线而不会二次 dispose。
class WebViewPrewarmSession {
  WebViewPrewarmSession({
    required Future<void> Function() disposeWebView,
    Duration timeout = kDefaultTimeout,
    void Function(String reason)? onFinished,
  }) : _disposeWebView = disposeWebView,
       _timeout = timeout,
       _onFinished = onFinished;

  /// 兜底时限：预热收益只有几百毫秒到 1.5 秒，超过这个量级还没回调就已经没有
  /// 预热价值了，留着只剩泄漏成本。不是「等久一点也许就好了」的重试窗口。
  static const Duration kDefaultTimeout = Duration(seconds: 30);

  final Future<void> Function() _disposeWebView;
  final Duration _timeout;
  final void Function(String reason)? _onFinished;

  Timer? _timer;
  bool _finished = false;

  /// 预热是否已终结（dispose 已发起）。
  bool get isFinished => _finished;

  /// 兜底定时器是否在跑。仅供测试与诊断。
  bool get hasPendingTimeout => _timer != null;

  /// 在 headless WebView 真的 `run()` 起来之后调用：装上兜底终点。
  ///
  /// 已终结时不再装（回调可能比 `run()` 返回还快）。
  void armTimeout() {
    if (_finished || _timer != null) return;
    _timer = Timer(_timeout, () {
      unawaited(finish('timeout'));
    });
  }

  /// 终结预热并销毁 WebView。先到者胜，重复调用是 no-op。
  ///
  /// dispose 抛错只记原因、不外抛：预热失败不该冒泡进启动链路。
  Future<void> finish(String reason) async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    String outcome = reason;
    try {
      await _disposeWebView();
    } catch (e) {
      outcome = '$reason (dispose failed: $e)';
    }
    _onFinished?.call(outcome);
  }
}
